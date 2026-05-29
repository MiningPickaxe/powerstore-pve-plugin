package PVE::Storage::Custom::PowerStorePlugin;
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# PowerStore PVE Plugin — Proxmox VE storage plugin for Dell PowerStore appliances.
# Provides native iSCSI block storage with full snapshot and clone support.
#
# Copyright (C) 2026  PowerStore PVE Plugin Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Repository: https://github.com/powerstore-pve-plugin/powerstore-pve-plugin

use strict;
use warnings;
use 5.020;

use base qw(PVE::Storage::Plugin);

use MIME::Base64 qw(encode_base64);
use JSON         qw(encode_json decode_json);
use LWP::UserAgent;
use HTTP::Request;
use Sys::Syslog  qw(:standard :macros);
use POSIX        qw(mktime);

our $VERSION = '1.0.0';

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

use constant {
    # PVE Storage Plugin API version this plugin targets.
    # Increment when adopting new PVE API features.
    APIVER  => 10,
    APIAGE  => 1,

    PS_API_BASE         => '/api/rest',

    # Block device discovery timeouts
    DEVICE_WAIT_SEC     => 30,    # seconds to wait for /dev/disk/by-id/wwn-...
    DEVICE_POLL_INT     => 0.5,   # poll interval in seconds

    # Re-authenticate this many seconds before the token expires
    SESSION_REFRESH_SEC => 60,

    # Maximum vm-<vmid>-disk-N index to probe
    MAX_DISK_INDEX      => 999,
};

# ---------------------------------------------------------------------------
# Package-level session cache — keyed by api_host
# { token => '...', cookie => '...', expires => epoch, ua => LWP::UserAgent }
# ---------------------------------------------------------------------------
my %_SESSION_CACHE;

# ===========================================================================
# Plugin registration methods
# ===========================================================================

sub api { return APIVER; }

sub type { return 'powerstoreplugin'; }

sub plugindata {
    return {
        content => [ { images => 1, none => 1 }, { images => 1 } ],
        format  => [ { raw    => 1 }, 'raw' ],
        shared  => 1,
    };
}

sub properties {
    return {
        api_host => {
            description => 'Hostname or IP address of the PowerStore management interface.',
            type        => 'string',
        },
        api_user => {
            description => 'PowerStore management username.',
            type        => 'string',
            default     => 'admin',
        },
        api_password => {
            description => 'PowerStore management password.',
            type        => 'string',
        },
        pool_id => {
            description =>
                'PowerStore storage pool ID (UUID). All volumes are created in this pool. '
              . 'Find it via: GET https://<host>/api/rest/storage_pool',
            type => 'string',
        },
        api_port => {
            description => 'PowerStore HTTPS management port.',
            type        => 'integer',
            minimum     => 1,
            maximum     => 65535,
            default     => 443,
        },
        api_insecure => {
            description =>
                'Disable TLS certificate verification. Only use for testing with self-signed certs.',
            type    => 'boolean',
            default => 0,
        },
        transport_mode => {
            description => 'Block storage transport protocol.',
            type        => 'string',
            enum        => ['iscsi'],
            default     => 'iscsi',
        },
        portal => {
            description =>
                'iSCSI discovery portal IP or hostname. '
              . 'Defaults to api_host when omitted; explicitly setting this is recommended.',
            type => 'string',
        },
        host_name_prefix => {
            description =>
                'Prefix for PowerStore Host entries auto-created by this plugin.',
            type    => 'string',
            default => 'pve-',
        },
        chap_user => {
            description => 'CHAP username for iSCSI authentication (optional).',
            type        => 'string',
        },
        chap_password => {
            description => 'CHAP password for iSCSI authentication (optional).',
            type        => 'string',
        },
        performance_policy_id => {
            description =>
                'PowerStore performance policy UUID to apply to newly created volumes (optional).',
            type => 'string',
        },
        debug => {
            description => 'Plugin log verbosity: 0=errors only, 1=info, 2=verbose.',
            type        => 'integer',
            minimum     => 0,
            maximum     => 2,
            default     => 0,
        },
    };
}

sub options {
    return {
        # Required
        api_host             => {},
        api_password         => {},
        pool_id              => {},
        # Optional (have defaults or are situational)
        api_user             => { optional => 1 },
        api_port             => { optional => 1 },
        api_insecure         => { optional => 1 },
        transport_mode       => { optional => 1 },
        portal               => { optional => 1 },
        host_name_prefix     => { optional => 1 },
        chap_user            => { optional => 1 },
        chap_password        => { optional => 1 },
        performance_policy_id => { optional => 1 },
        debug                => { optional => 1 },
        # Standard PVE storage options (inherited from base plugin)
        nodes                => { optional => 1 },
        disable              => { optional => 1 },
        content              => { optional => 1 },
        shared               => { optional => 1 },
        maxfiles             => { optional => 1 },
        'prune-backups'      => { optional => 1 },
    };
}

# ===========================================================================
# Volume name handling
# ===========================================================================

sub parse_volname {
    my ( $class, $volname ) = @_;

    if ( $volname =~ m/^(vm|base)-(\d+)-disk-(\d+)$/ ) {
        my ( $prefix, $vmid ) = ( $1, $2 );
        my $isBase = ( $prefix eq 'base' ) ? 1 : 0;
        return ( 'images', $volname, $vmid, undef, undef, $isBase, 'raw' );
    }

    die "unable to parse PowerStore volume name '$volname'\n";
}

# Returns ($path, $vmid, $vtype) for block-device volumes.
# Called by Proxmox before mounting/accessing a volume.
sub filesystem_path {
    my ( $class, $scfg, $volname, $snapname ) = @_;

    die "direct snapshot access is not supported for PowerStore volumes\n"
        if defined $snapname;

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $vol = _ps_get_volume_by_name( $scfg, $name )
        or die "PowerStore volume '$name' not found\n";

    my $wwn = $vol->{wwn}
        or die "Volume '$name' has no WWN — cannot determine block device path\n";

    my $path = _device_path_for_wwn($wwn)
        or die "Block device for volume '$name' (wwn=$wwn) not found."
              . " Is the volume activated on this node?\n";

    return ( $path, $vmid, $vtype );
}

# Alias that Proxmox uses for block-device storage
sub path {
    my ( $class, $scfg, $volname, $storeid, $snapname ) = @_;
    return $class->filesystem_path( $scfg, $volname, $snapname );
}

# ===========================================================================
# Feature detection
# ===========================================================================

sub volume_has_feature {
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) = @_;

    my %features = (
        snapshot => 1,
        clone    => 1,
        copy     => 1,
        discard  => 1,   # PowerStore supports UNMAP/TRIM
        erase    => 0,
        wipe     => 0,
    );

    # Cannot snapshot an existing snapshot
    return 0 if defined $snapname && $feature eq 'snapshot';

    return $features{$feature} // 0;
}

# ===========================================================================
# Logging
# ===========================================================================

# _ps_log($scfg, $level, $msg)
# Levels: 0=error, 1=info, 2=debug
# Only emits messages at or below the configured debug level.
sub _ps_log {
    my ( $scfg, $level, $msg ) = @_;
    my $configured = $scfg->{debug} // 0;
    return if $level > $configured;

    my $tag = 'PowerStorePlugin';
    if ( $level == 0 ) {
        syslog( LOG_ERR,    "$tag: ERROR: $msg" );
        warn "$tag: ERROR: $msg\n";
    }
    elsif ( $level == 1 ) {
        syslog( LOG_NOTICE, "$tag: $msg" );
    }
    else {
        syslog( LOG_DEBUG,  "$tag: DEBUG: $msg" );
    }
}

# ===========================================================================
# HTTP / REST API client
# ===========================================================================

sub _api_base_url {
    my ($scfg) = @_;
    my $host = $scfg->{api_host};
    my $port = $scfg->{api_port} // 443;
    return "https://${host}:${port}" . PS_API_BASE;
}

sub _make_ua {
    my ($scfg) = @_;
    my $insecure = $scfg->{api_insecure} // 0;
    my $ua = LWP::UserAgent->new(
        timeout    => 30,
        keep_alive => 4,
        agent      => "powerstore-pve-plugin/$VERSION",
    );
    if ($insecure) {
        $ua->ssl_opts(
            verify_hostname => 0,
            SSL_verify_mode => 0x00,
        );
    }
    return $ua;
}

# Authenticate and cache the session token + cookie.
sub _api_login {
    my ($scfg) = @_;
    my $host = $scfg->{api_host};
    my $user = $scfg->{api_user}     // 'admin';
    my $pass = $scfg->{api_password} // die "api_password not configured\n";

    _ps_log( $scfg, 2, "Authenticating to PowerStore at $host as '$user'" );

    my $credentials = encode_base64( "${user}:${pass}", '' );
    my $url         = _api_base_url($scfg) . '/login_session';

    my $ua  = _make_ua($scfg);
    my $req = HTTP::Request->new( GET => $url );
    $req->header( 'Authorization' => "Basic $credentials" );
    $req->header( 'Accept'        => 'application/json' );

    my $resp = $ua->request($req);

    unless ( $resp->is_success ) {
        die sprintf(
            "PowerStore login failed (HTTP %d): %s\n",
            $resp->code, $resp->decoded_content // ''
        );
    }

    my $token = $resp->header('DELL-EMC-TOKEN')
        or die "PowerStore login: no DELL-EMC-TOKEN in response headers\n";

    # Extract auth_cookie from Set-Cookie header(s)
    my $cookie = '';
    $resp->scan( sub {
        my ( $name, $val ) = @_;
        if ( lc($name) eq 'set-cookie' && $val =~ /auth_cookie=([^;]+)/ ) {
            $cookie = $1;
        }
    } );
    die "PowerStore login: no auth_cookie in response\n" unless $cookie;

    my $body      = eval { decode_json( $resp->decoded_content ) } // {};
    my $idle_ttl  = $body->{idle_timeout} // 1800;

    $_SESSION_CACHE{$host} = {
        token   => $token,
        cookie  => $cookie,
        expires => time() + $idle_ttl - SESSION_REFRESH_SEC,
        ua      => $ua,
    };

    _ps_log( $scfg, 2,
        "Login successful; session valid for ~${idle_ttl}s" );

    return $_SESSION_CACHE{$host};
}

sub _get_session {
    my ($scfg) = @_;
    my $host    = $scfg->{api_host};
    my $session = $_SESSION_CACHE{$host};
    if ( !$session || time() >= $session->{expires} ) {
        $session = _api_login($scfg);
    }
    return $session;
}

# _api_call($scfg, $method, $path, $body_hashref)
# Executes an authenticated REST call. Returns decoded response hashref/arrayref,
# or {} on 204 No Content. Dies on HTTP errors with a descriptive message.
sub _api_call {
    my ( $scfg, $method, $path, $body ) = @_;

    my $max_attempts = 3;
    my $delay        = 1;

    for my $attempt ( 1 .. $max_attempts ) {
        my $session = _get_session($scfg);
        my $url     = _api_base_url($scfg) . $path;

        _ps_log( $scfg, 2,
            "$method $path" . ( $body ? ' body=' . encode_json($body) : '' ) );

        my $req = HTTP::Request->new( $method => $url );
        $req->header( 'DELL-EMC-TOKEN' => $session->{token} );
        $req->header( 'Cookie'         => "auth_cookie=$session->{cookie}" );
        $req->header( 'Accept'         => 'application/json' );
        if ($body) {
            $req->header( 'Content-Type' => 'application/json' );
            $req->content( encode_json($body) );
        }

        my $resp    = $session->{ua}->request($req);
        my $code    = $resp->code;
        my $content = $resp->decoded_content // '';

        _ps_log( $scfg, 2, "Response: HTTP $code" );

        # --- Success ---
        if ( $code == 200 || $code == 201 || $code == 206 ) {
            return eval { decode_json($content) } // {};
        }
        if ( $code == 204 ) {
            return {};    # No Content — successful write/delete
        }

        # --- Auth failure — force re-login ---
        if ( $code == 401 ) {
            delete $_SESSION_CACHE{ $scfg->{api_host} };
            if ( $attempt < $max_attempts ) {
                _ps_log( $scfg, 1,
                    "Auth failure on attempt $attempt; re-authenticating in ${delay}s" );
                sleep($delay);
                $delay *= 2;
                next;
            }
        }

        # --- Transient server error — retry with backoff ---
        if ( $code >= 500 && $attempt < $max_attempts ) {
            _ps_log( $scfg, 1,
                "Server error $code on attempt $attempt; retrying in ${delay}s" );
            sleep($delay);
            $delay *= 2;
            next;
        }

        # --- Parse PowerStore error payload ---
        my $errmsg  = "HTTP $code";
        my $errdata = eval { decode_json($content) };
        if ( $errdata && ref $errdata eq 'HASH' && $errdata->{messages} ) {
            my @msgs = map {
                $_->{message_l10n} // $_->{message} // ''
            } @{ $errdata->{messages} };
            $errmsg .= ': ' . join( '; ', grep { length } @msgs ) if @msgs;
        }
        elsif ($content) {
            $errmsg .= ": $content";
        }

        die "PowerStore API error [$method $path]: $errmsg\n";
    }

    die "PowerStore API call [$method $path] failed after $max_attempts attempts\n";
}

sub _api_logout {
    my ($scfg) = @_;
    my $host    = $scfg->{api_host};
    my $session = $_SESSION_CACHE{$host} or return;
    eval {
        my $url = _api_base_url($scfg) . '/logout';
        my $req = HTTP::Request->new( POST => $url );
        $req->header( 'DELL-EMC-TOKEN' => $session->{token} );
        $req->header( 'Cookie'         => "auth_cookie=$session->{cookie}" );
        $session->{ua}->request($req);
    };
    delete $_SESSION_CACHE{$host};
}

# ===========================================================================
# PowerStore volume helpers
# ===========================================================================

# Standard select string — include all fields needed across operations
use constant PS_VOL_SELECT =>
    'id,name,size,wwn,type,mapped_volumes,storage_pool_id,protection_data,creation_timestamp';

sub _ps_create_volume {
    my ( $scfg, $name, $size_bytes, $perf_policy_id ) = @_;

    my $body = {
        name            => $name,
        size            => $size_bytes + 0,    # ensure numeric (avoid JSON string)
        storage_pool_id => $scfg->{pool_id},
    };
    $body->{performance_policy_id} = $perf_policy_id if $perf_policy_id;

    my $result = _api_call( $scfg, 'POST', '/volume', $body );
    die "volume create returned no id\n" unless $result->{id};
    return $result;
}

sub _ps_get_volume {
    my ( $scfg, $vol_id ) = @_;
    return _api_call( $scfg, 'GET',
        '/volume/' . $vol_id . '?select=' . PS_VOL_SELECT );
}

sub _ps_get_volume_by_name {
    my ( $scfg, $name ) = @_;
    ( my $ename = $name ) =~
        s/([^A-Za-z0-9\-_.~])/sprintf( '%%%02X', ord($1) )/ge;
    my $result = _api_call( $scfg, 'GET',
        '/volume?name=eq.' . $ename . '&select=' . PS_VOL_SELECT );
    return ref $result eq 'ARRAY' ? $result->[0] : undef;
}

# Returns arrayref of primary + clone volumes in the configured pool.
# Pass $include_snapshots=1 to also return Snapshot-type volumes.
sub _ps_list_volumes {
    my ( $scfg, $include_snapshots ) = @_;
    my $pool_id     = $scfg->{pool_id};
    my $type_filter = $include_snapshots ? '' : '&type=neq.Snapshot';
    my $result = _api_call( $scfg, 'GET',
            '/volume?storage_pool_id=eq.'
          . $pool_id
          . $type_filter
          . '&select='
          . PS_VOL_SELECT );
    return ref $result eq 'ARRAY' ? $result : [];
}

# Returns arrayref of Snapshot-type volumes whose source is $vol_id.
sub _ps_list_snapshots_of {
    my ( $scfg, $vol_id ) = @_;
    my $result = _api_call( $scfg, 'GET',
            '/volume?protection_data.source_id=eq.'
          . $vol_id
          . '&type=eq.Snapshot&select='
          . PS_VOL_SELECT );
    return ref $result eq 'ARRAY' ? $result : [];
}

sub _ps_delete_volume {
    my ( $scfg, $vol_id ) = @_;
    _api_call( $scfg, 'DELETE', "/volume/$vol_id" );
}

sub _ps_resize_volume {
    my ( $scfg, $vol_id, $new_size_bytes ) = @_;
    _api_call( $scfg, 'PATCH', "/volume/$vol_id",
        { size => $new_size_bytes + 0 } );
}

# ===========================================================================
# PowerStore snapshot helpers
# ===========================================================================

sub _ps_create_snapshot {
    my ( $scfg, $vol_id, $snap_name ) = @_;
    my $result = _api_call( $scfg, 'POST', "/volume/$vol_id/snapshot",
        { name => $snap_name } );
    die "snapshot create returned no id\n" unless $result->{id};
    return $result;
}

sub _ps_delete_snapshot {
    my ( $scfg, $snap_id ) = @_;
    _api_call( $scfg, 'DELETE', "/volume/$snap_id" );
}

# Restore $vol_id to the state captured in $snap_id.
sub _ps_restore_volume {
    my ( $scfg, $vol_id, $snap_id ) = @_;
    _api_call( $scfg, 'POST', "/volume/$vol_id/restore",
        {
            snap_id_to_restore_from => $snap_id,
            create_backup_snap      => \0,        # JSON false
        }
    );
}

# Clone a snapshot (or any volume) into a new independently-named volume.
sub _ps_clone_volume {
    my ( $scfg, $source_id, $clone_name ) = @_;
    my $result = _api_call( $scfg, 'POST', "/volume/$source_id/clone",
        { name => $clone_name } );
    die "clone returned no id\n" unless $result->{id};
    return $result;
}

# ===========================================================================
# PowerStore host and volume-mapping helpers
# ===========================================================================

# Return the trimmed IQN from the local node's initiatorname file.
sub _get_local_iqn {
    my $file = '/etc/iscsi/initiatorname.iscsi';
    open( my $fh, '<', $file )
        or die "Cannot read iSCSI initiator name from $file: $!\n";
    while ( my $line = <$fh> ) {
        chomp $line;
        return $1 if $line =~ /^InitiatorName=(.+)$/;
    }
    close $fh;
    die "No InitiatorName entry found in $file\n";
}

sub _get_hostname {
    my $h = `hostname -s 2>/dev/null`;
    chomp $h;
    return $h || 'pve-node';
}

# Find a PowerStore Host by iSCSI IQN. Returns host hashref or undef.
sub _ps_get_host_by_iqn {
    my ( $scfg, $iqn ) = @_;
    ( my $eiqn = $iqn ) =~
        s/([^A-Za-z0-9\-_.~:])/ sprintf( '%%%02X', ord($1) )/ge;
    my $result = _api_call( $scfg, 'GET',
        '/host?initiators.port_name=eq.'
      . $eiqn
      . '&select=id,name,initiators,mapped_volumes' );
    return ref $result eq 'ARRAY' && @$result ? $result->[0] : undef;
}

sub _ps_create_host {
    my ( $scfg, $iqn, $name, $chap_user, $chap_pass ) = @_;

    my $initiator = { port_name => $iqn, port_type => 'iSCSI' };
    if ( $chap_user && $chap_pass ) {
        $initiator->{chap_single_username} = $chap_user;
        $initiator->{chap_single_password} = $chap_pass;
    }

    my $result = _api_call( $scfg, 'POST', '/host',
        {
            name       => $name,
            os_type    => 'Linux',
            initiators => [$initiator],
        }
    );
    die "host create returned no id\n" unless $result->{id};
    return $result;
}

# Idempotent: returns existing or newly created host ID for the local node.
sub _ps_get_or_create_host {
    my ($scfg) = @_;
    my $iqn  = _get_local_iqn();
    my $host = _ps_get_host_by_iqn( $scfg, $iqn );
    return $host->{id} if $host;

    my $prefix = $scfg->{host_name_prefix} // 'pve-';
    my $hname  = $prefix . _get_hostname();
    _ps_log( $scfg, 1,
        "Creating PowerStore host '$hname' for IQN $iqn" );
    my $new = _ps_create_host(
        $scfg, $iqn, $hname,
        $scfg->{chap_user}, $scfg->{chap_password}
    );
    return $new->{id};
}

# Attach a volume to a host. Returns the assigned LUN number.
# If already attached, returns the existing LUN without error.
sub _ps_attach_volume {
    my ( $scfg, $vol_id, $host_id ) = @_;

    # Check if already attached before sending the attach request
    my $lun = _ps_get_volume_lun_for_host( $scfg, $vol_id, $host_id );
    return $lun if defined $lun;

    _api_call( $scfg, 'POST', "/volume/$vol_id/attach",
        { host_id => $host_id } );

    # Retrieve LUN assigned by the array
    $lun = _ps_get_volume_lun_for_host( $scfg, $vol_id, $host_id );
    die "Volume $vol_id attached but LUN number could not be determined\n"
        unless defined $lun;
    return $lun;
}

# Look up the LUN number assigned to $host_id for $vol_id.
# Returns undef if not attached to that host.
sub _ps_get_volume_lun_for_host {
    my ( $scfg, $vol_id, $host_id ) = @_;
    my $vol      = _ps_get_volume( $scfg, $vol_id );
    my $mappings = $vol->{mapped_volumes} // [];
    for my $m (@$mappings) {
        return $m->{logical_unit_number}
            if ( $m->{host_id} // '' ) eq $host_id;
    }
    return undef;
}

# Detach a volume from a host. Silently ignores "already detached" errors.
sub _ps_detach_volume {
    my ( $scfg, $vol_id, $host_id ) = @_;
    eval {
        _api_call( $scfg, 'POST', "/volume/$vol_id/detach",
            { host_id => $host_id } );
    };
    if ($@) {
        # Log but do not die — volume may already be detached
        _ps_log( $scfg, 1, "Detach note (may already be detached): $@" );
    }
}

# Return list of portal IP addresses for iSCSI discovery.
# Uses the 'portal' config param if set; otherwise attempts API discovery;
# falls back to the management IP as a last resort.
sub _get_portals {
    my ($scfg) = @_;

    # Explicit configuration always wins
    if ( my $portal = $scfg->{portal} ) {
        return [$portal];
    }

    # Attempt auto-discovery from PowerStore API
    my @ips;
    my $result = eval {
        _api_call( $scfg, 'GET',
            '/ip_port?select=id,name,target_iqn,current_usages,'
          . 'current_address,configured_address' );
    };
    if ( !$@ && ref $result eq 'ARRAY' ) {
        for my $port (@$result) {
            my $usages = $port->{current_usages} // [];
            $usages = [$usages] unless ref $usages eq 'ARRAY';
            next unless grep { /iSCSI/i } @$usages;

            my $addr =
                 $port->{current_address}
              // $port->{configured_address}
              // next;

            $addr =~ s{/\d+$}{};    # strip CIDR prefix

            # Accept IPv4 or bracketed IPv6
            if ( $addr =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ || $addr =~ /^[0-9a-f:]+$/i ) {
                push @ips, $addr;
            }
        }
    }

    unless (@ips) {
        _ps_log( $scfg, 1,
            "Could not auto-discover iSCSI portals; falling back to api_host" );
        push @ips, $scfg->{api_host};
    }

    return \@ips;
}

# ===========================================================================
# iSCSI helpers
# ===========================================================================

# Run a command and return (exit_code, combined_output).
sub _run_cmd {
    my (@cmd) = @_;
    my $cmdstr = join( ' ', @cmd );
    my $output = `$cmdstr 2>&1`;
    my $exit   = $? >> 8;
    return ( $exit, $output );
}

sub _iscsi_discover {
    my ($portal) = @_;
    _run_cmd( 'iscsiadm', '-m', 'discovery', '-t', 'sendtargets',
        '-p', "${portal}:3260" );
}

sub _iscsi_login_all {
    _run_cmd( 'iscsiadm', '-m', 'node', '--loginall=automatic' );
}

sub _scan_iscsi_sessions {
    _run_cmd( 'iscsiadm', '-m', 'session', '--rescan' );
}

# Compute the canonical /dev/disk/by-id/wwn-0x... path for a PowerStore WWN.
sub _device_path_for_wwn {
    my ($wwn) = @_;
    return undef unless $wwn;
    $wwn = lc($wwn);
    $wwn =~ s/^naa\.//;    # strip optional NAA prefix
    return "/dev/disk/by-id/wwn-0x${wwn}";
}

# Poll until the block device symlink exists or timeout is reached.
sub _wait_for_device {
    my ( $wwn, $timeout ) = @_;
    $timeout //= DEVICE_WAIT_SEC;

    my $path     = _device_path_for_wwn($wwn);
    my $deadline = time() + $timeout;

    while ( time() < $deadline ) {
        return $path if -b $path;
        select( undef, undef, undef, DEVICE_POLL_INT );
    }

    die "Timed out (${timeout}s) waiting for block device $path to appear. "
      . "Ensure iSCSI sessions are established and the volume is attached.\n";
}

# Tell the kernel to remove a SCSI device to avoid stale entries after detach.
sub _remove_scsi_device {
    my ($wwn) = @_;
    my $by_id = _device_path_for_wwn($wwn) or return;
    return unless -b $by_id;

    my $realdev = readlink($by_id) or return;
    $realdev = "/dev/$realdev" unless $realdev =~ m{^/dev/};
    ( my $devname = $realdev ) =~ s{^/dev/}{};

    my $delete_path = "/sys/block/${devname}/device/delete";
    if ( -f $delete_path ) {
        if ( open( my $fh, '>', $delete_path ) ) {
            print $fh "1\n";
            close $fh;
        }
    }
}

# Trigger a SCSI rescan so the kernel picks up a size change.
sub _rescan_scsi_device {
    my ($wwn) = @_;
    my $by_id = _device_path_for_wwn($wwn) or return;
    return unless -b $by_id;

    my $realdev = readlink($by_id) or return;
    $realdev = "/dev/$realdev" unless $realdev =~ m{^/dev/};
    ( my $devname = $realdev ) =~ s{^/dev/}{};

    my $rescan = "/sys/block/${devname}/device/rescan";
    if ( -f $rescan ) {
        if ( open( my $fh, '>', $rescan ) ) {
            print $fh "1\n";
            close $fh;
        }
    }
}

# ===========================================================================
# Naming helpers
# ===========================================================================

# Return the next free disk-N index for a given vmid.
sub _next_free_disk_index {
    my ( $scfg, $vmid ) = @_;
    my $vols = _ps_list_volumes( $scfg, 0 );
    my %used;
    for my $v (@$vols) {
        $used{$1} = 1 if ( $v->{name} // '' ) =~ /^(?:vm|base)-${vmid}-disk-(\d+)$/;
    }
    for my $i ( 0 .. MAX_DISK_INDEX ) {
        return $i unless $used{$i};
    }
    die "No free disk index for vmid $vmid (limit " . MAX_DISK_INDEX . " reached)\n";
}

# Convert a Proxmox snapshot name to the PowerStore snapshot name.
# PowerStore snapshot names are scoped per parent volume, so they only
# need to be unique within that volume's snapshot list.
sub _snap_ps_name {
    my ($snapname) = @_;
    return "snap_${snapname}";
}

# Convert a PowerStore snapshot name back to a Proxmox snapshot name.
# Returns undef if the name does not match our naming convention.
sub _snap_proxmox_name {
    my ($ps_name) = @_;
    return $1 if $ps_name =~ /^snap_(.+)$/;
    return undef;
}

# Parse an ISO 8601 timestamp from PowerStore into a Unix epoch.
sub _parse_timestamp {
    my ($ts) = @_;
    return 0 unless $ts;
    if ( $ts =~
        /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/ )
    {
        return mktime( $6, $5, $4, $3, $2 - 1, $1 - 1900 );
    }
    return 0;
}

# ===========================================================================
# Core PVE storage operations
# ===========================================================================

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $pool_id = $scfg->{pool_id};
    my $pool    = eval {
        _api_call( $scfg, 'GET',
            "/storage_pool/${pool_id}?select=id,name,size_total,size_used,size_free" );
    };
    if ($@) {
        warn "PowerStorePlugin: status() error: $@";
        return { total => 0, avail => 0, used => 0, active => 0 };
    }

    my $total = $pool->{size_total} // 0;
    my $used  = $pool->{size_used}  // 0;
    my $free  = $pool->{size_free}  // ( $total - $used );

    return {
        total  => $total + 0,
        avail  => $free  + 0,
        used   => $used  + 0,
        active => 1,
    };
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    # PVE passes $size in KiB
    my $size_bytes = ( $size + 0 ) * 1024;

    unless ($name) {
        my $idx = _next_free_disk_index( $scfg, $vmid );
        $name = "vm-${vmid}-disk-${idx}";
    }

    _ps_log( $scfg, 1,
        "alloc_image: vmid=$vmid name=$name size=${size_bytes}B" );

    # 1. Create volume on PowerStore
    my $vol = _ps_create_volume(
        $scfg, $name, $size_bytes, $scfg->{performance_policy_id}
    );
    my $vol_id = $vol->{id};

    # 2. Register local host and attach
    my $host_id = _ps_get_or_create_host($scfg);
    my $lun     = _ps_attach_volume( $scfg, $vol_id, $host_id );
    _ps_log( $scfg, 1, "Attached '$name' as LUN $lun" );

    # 3. Trigger iSCSI rescan and wait for device
    _scan_iscsi_sessions();
    my $vol_detail = _ps_get_volume( $scfg, $vol_id );
    my $wwn = $vol_detail->{wwn}
        or die "Volume '$name' returned no WWN from PowerStore\n";

    _wait_for_device($wwn);
    _ps_log( $scfg, 1,
        "alloc_image: '$name' ready at " . _device_path_for_wwn($wwn) );

    return $name;
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $format ) = @_;

    _ps_log( $scfg, 1, "free_image: $volname" );

    my $vol = _ps_get_volume_by_name( $scfg, $volname );
    unless ($vol) {
        warn "PowerStorePlugin: volume '$volname' not found; skipping delete\n";
        return;
    }

    my $vol_id   = $vol->{id};
    my $wwn      = $vol->{wwn};
    my $mappings = $vol->{mapped_volumes} // [];

    # Detach from every host that has the volume mapped
    for my $m (@$mappings) {
        my $hid = $m->{host_id} or next;
        _ps_log( $scfg, 2, "Detaching '$volname' from host $hid" );
        _ps_detach_volume( $scfg, $vol_id, $hid );
    }

    # Remove SCSI device from kernel before deleting
    _remove_scsi_device($wwn) if $wwn;

    _ps_delete_volume( $scfg, $vol_id );
    _ps_log( $scfg, 1, "free_image: '$volname' deleted" );
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    # Cache volume list for the duration of this PVE operation cycle
    my $cache_key = "ps_volumes_$storeid";
    $cache->{$cache_key} //= _ps_list_volumes( $scfg, 0 );
    my $vols = $cache->{$cache_key};

    my @result;
    for my $vol (@$vols) {
        my $vname = $vol->{name} // next;

        # Only return volumes following our naming convention
        next unless $vname =~ /^(?:vm|base)-(\d+)-disk-\d+$/;
        my $owner_vmid = $1 + 0;

        next if defined $vmid && $owner_vmid != $vmid;

        my $volid = "$storeid:$vname";
        if ($vollist) {
            next unless grep { $_ eq $volid } @$vollist;
        }

        push @result, {
            volid   => $volid,
            content => 'images',
            size    => ( $vol->{size} // 0 ) + 0,
            vmid    => $owner_vmid,
            format  => 'raw',
            ctime   => _parse_timestamp( $vol->{creation_timestamp} ),
        };
    }

    return \@result;
}

sub volume_size_info {
    my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;

    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Volume '$volname' not found on PowerStore\n";

    my $size = ( $vol->{size} // 0 ) + 0;
    return wantarray ? ( $size, 'raw', $size ) : $size;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    # $size is the new size in bytes
    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Volume '$volname' not found on PowerStore\n";

    my $current = $vol->{size} + 0;
    die "Cannot shrink PowerStore volumes "
      . "(current=${current}B, requested=${size}B)\n"
        if $size < $current;

    return $size if $size == $current;    # no-op

    _ps_log( $scfg, 1,
        "Resizing '$volname' from ${current}B to ${size}B" );
    _ps_resize_volume( $scfg, $vol->{id}, $size );

    # Notify the kernel of the new size
    _scan_iscsi_sessions();
    _rescan_scsi_device( $vol->{wwn} ) if $vol->{wwn};

    return $size;
}

# ===========================================================================
# Snapshot operations
# ===========================================================================

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;

    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Volume '$volname' not found\n";

    my $ps_name = _snap_ps_name($snap);
    _ps_log( $scfg, 1,
        "Creating snapshot '$ps_name' on volume '$volname'" );
    _ps_create_snapshot( $scfg, $vol->{id}, $ps_name );
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;

    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Volume '$volname' not found\n";

    my $ps_name  = _snap_ps_name($snap);
    my $snaps    = _ps_list_snapshots_of( $scfg, $vol->{id} );
    my ($snap_obj) = grep { ( $_->{name} // '' ) eq $ps_name } @$snaps;
    die "Snapshot '$snap' not found on volume '$volname'\n" unless $snap_obj;

    _ps_log( $scfg, 1,
        "Deleting snapshot '$ps_name' from '$volname'" );
    _ps_delete_snapshot( $scfg, $snap_obj->{id} );
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Volume '$volname' not found\n";

    my $ps_name  = _snap_ps_name($snap);
    my $snaps    = _ps_list_snapshots_of( $scfg, $vol->{id} );
    my ($snap_obj) = grep { ( $_->{name} // '' ) eq $ps_name } @$snaps;
    die "Snapshot '$snap' not found on volume '$volname'\n" unless $snap_obj;

    _ps_log( $scfg, 1,
        "Restoring '$volname' from snapshot '$ps_name'" );
    _ps_restore_volume( $scfg, $vol->{id}, $snap_obj->{id} );

    # After restore the OS-visible data changes; rescan to reflect it
    _scan_iscsi_sessions();
    _rescan_scsi_device( $vol->{wwn} ) if $vol->{wwn};
}

# Returns hashref: { $proxmox_snap_name => { id, timestamp }, ... }
sub volume_snapshot_info {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    my $vol = _ps_get_volume_by_name( $scfg, $volname );
    return {} unless $vol;

    my $snaps = _ps_list_snapshots_of( $scfg, $vol->{id} );
    my %info;
    for my $s (@$snaps) {
        my $ps_name = $s->{name} // next;
        my $pve_name = _snap_proxmox_name($ps_name) // next;
        $info{$pve_name} = {
            id        => $s->{id},
            timestamp => _parse_timestamp( $s->{creation_timestamp} ),
        };
    }
    return \%info;
}

# ===========================================================================
# Clone / copy operations
# ===========================================================================

sub clone_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap, $name, $format,
        $running ) = @_;

    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Source volume '$volname' not found\n";

    unless ($name) {
        my $idx = _next_free_disk_index( $scfg, $vmid );
        $name = "vm-${vmid}-disk-${idx}";
    }

    my ( $source_id, $temp_snap_id );

    if ($snap) {
        # Clone from a named snapshot
        my $ps_name = _snap_ps_name($snap);
        my $snaps   = _ps_list_snapshots_of( $scfg, $vol->{id} );
        my ($snap_obj) = grep { ( $_->{name} // '' ) eq $ps_name } @$snaps;
        die "Snapshot '$snap' not found on '$volname'\n" unless $snap_obj;
        $source_id = $snap_obj->{id};
    }
    else {
        # Create a temporary snapshot to clone from (ensures consistent state)
        my $tmp_name = 'snap_clone_tmp_' . $$;
        my $tmp      = _ps_create_snapshot( $scfg, $vol->{id}, $tmp_name );
        $source_id    = $tmp->{id};
        $temp_snap_id = $tmp->{id};
    }

    _ps_log( $scfg, 1,
        "Cloning '$volname' (snap=" . ( $snap // 'temp' ) . ") -> '$name'" );

    my $clone = eval { _ps_clone_volume( $scfg, $source_id, $name ) };
    my $err   = $@;

    # Always remove the temporary snapshot, even on clone failure
    if ($temp_snap_id) {
        eval { _ps_delete_snapshot( $scfg, $temp_snap_id ) };
        warn "PowerStorePlugin: could not remove temp snapshot: $@\n" if $@;
    }

    die $err if $err;

    # Attach clone to local host and wait for device
    my $host_id = _ps_get_or_create_host($scfg);
    _ps_attach_volume( $scfg, $clone->{id}, $host_id );

    _scan_iscsi_sessions();
    my $clone_detail = _ps_get_volume( $scfg, $clone->{id} );
    my $wwn = $clone_detail->{wwn}
        or die "Cloned volume '$name' has no WWN\n";
    _wait_for_device($wwn);

    return $name;
}

# PowerStore clone is always space-efficient (CoW); no separate full-copy path.
sub copy_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap, $name, $format,
        $running ) = @_;
    return $class->clone_image( $scfg, $storeid, $volname, $vmid, $snap,
        $name, $format, $running );
}

# ===========================================================================
# Storage and volume activation
# ===========================================================================

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    _ps_log( $scfg, 1, "activate_storage: $storeid" );

    # Verify API connectivity
    eval { _api_call( $scfg, 'GET', '/login_session' ) };
    die "Cannot reach PowerStore API at $scfg->{api_host}: $@\n" if $@;

    if ( ( $scfg->{transport_mode} // 'iscsi' ) eq 'iscsi' ) {
        my $portals = _get_portals($scfg);
        for my $portal (@$portals) {
            _ps_log( $scfg, 1, "iSCSI discovery on $portal" );
            _iscsi_discover($portal);
        }
        _iscsi_login_all();
    }

    return 1;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    return 1;    # Persistent iSCSI sessions are managed at OS level
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $exclusive, $cache ) = @_;

    _ps_log( $scfg, 1, "activate_volume: $volname" );

    my $vol = _ps_get_volume_by_name( $scfg, $volname )
        or die "Volume '$volname' not found on PowerStore\n";

    my $host_id = _ps_get_or_create_host($scfg);

    # Attach if not already mapped to this host
    my $lun = _ps_get_volume_lun_for_host( $scfg, $vol->{id}, $host_id );
    unless ( defined $lun ) {
        _ps_log( $scfg, 1, "Attaching '$volname' to local host" );
        $lun = _ps_attach_volume( $scfg, $vol->{id}, $host_id );
    }

    _scan_iscsi_sessions();

    my $wwn = $vol->{wwn}
        or die "Volume '$volname' has no WWN\n";
    _wait_for_device($wwn);

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $exclusive, $cache ) = @_;

    _ps_log( $scfg, 1, "deactivate_volume: $volname" );

    my $vol = _ps_get_volume_by_name( $scfg, $volname );
    return 1 unless $vol;

    my $iqn = eval { _get_local_iqn() };
    return 1 unless $iqn;

    my $host = eval { _ps_get_host_by_iqn( $scfg, $iqn ) };
    return 1 unless $host;

    my $wwn = $vol->{wwn};

    _ps_detach_volume( $scfg, $vol->{id}, $host->{id} );
    _remove_scsi_device($wwn) if $wwn;

    return 1;
}

1;

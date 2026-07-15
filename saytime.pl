#!/usr/bin/perl
#
# saytime.pl - ASL3 Time and Weather Announcement
# https://github.com/N6LKA/ASL3-Time-Weather-Announcement
#
# Original author: D. Crompton, WA3DSP
# Modified by: Larry K. Aycock, N6LKA
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Usage:
#   saytime.pl <locationID> <node>        - Announce time and weather
#   saytime.pl <node>                     - Announce time only
#   saytime.pl <locationID> <node> 1      - Build /tmp/current-time.gsm, no voice (for DTMF pre-build)
#   saytime.pl <locationID> <node> 2      - Build weather-only gsm, no voice
#
# weather.sh is called to refresh /tmp/temperature, /tmp/condition.gsm, etc.
# When the systemd weather timer is active those files are already fresh and
# weather.sh returns immediately without an API call.
#
# The weather cache files (/tmp/temperature, /tmp/condition.gsm, /tmp/feels-like,
# /tmp/humidity) are owned by the systemd timer and are NOT deleted by this script.

use strict;
use warnings;

select(STDOUT); $| = 1;
select(STDERR); $| = 1;

my $outdir  = "/tmp";
my $base    = "/usr/local/share/asterisk/sounds/custom";
my $confdir = "/etc/asterisk/scripts/saytime-weather";
my $wxsh    = "$confdir/weather.sh";

# Fall back to legacy path if not installed yet
unless (-f $wxsh) {
    $wxsh = "/usr/local/sbin/weather.sh";
}

# ---------- Read config ----------
my $time_format      = "12";
my $announce_feels   = "no";
my $announce_humidity = "no";

my @conf_paths = (
    "$confdir/weather.ini",
    "/etc/asterisk/local/weather.ini",
);

for my $cf (@conf_paths) {
    next unless -f $cf;
    open(my $fh, '<', $cf) or next;
    while (<$fh>) {
        chomp;
        s/#.*//;
        s/^\s+|\s+$//g;
        next unless length;
        if (/^TIME_FORMAT\s*=\s*"?(\d+)"?/)      { $time_format = $1; }
        if (/^ANNOUNCE_FEELS_LIKE\s*=\s*"?(\w+)"?/) { $announce_feels = lc($1); }
        if (/^ANNOUNCE_HUMIDITY\s*=\s*"?(\w+)"?/)   { $announce_humidity = lc($1); }
    }
    close($fh);
    last;
}

# ---------- Arguments ----------
my $num_args = scalar @ARGV;
my ($wxid, $mynode, $Silent) = ("", "", 0);
my $wx = "NO";
my $error = 0;

if ($num_args == 1) {
    $mynode = $ARGV[0];
} elsif ($num_args == 2) {
    $wxid   = $ARGV[0];
    $wx     = "YES";
    $mynode = $ARGV[1];
} elsif ($num_args == 3) {
    $wxid   = $ARGV[0];
    $wx     = "YES";
    $mynode = $ARGV[1];
    $Silent = $ARGV[2];
    if ($Silent < 0 || $Silent > 2) { $error = 1; }
} else {
    $error = 1;
}

if ($error) {
    print "\nUsage: saytime.pl [<locationid>] <nodenumber> [0|1|2]\n";
    print "  0 (default) = voice to node\n";
    print "  1 = save time+weather to /tmp/current-time.gsm, no voice\n";
    print "  2 = save weather-only to /tmp/current-time.gsm, no voice\n\n";
    exit 1;
}

unless (-f $wxsh) {
    $wx = "NO";
}

# ---------- Refresh weather cache ----------
# weather.sh exits 0 immediately if cache is already fresh (systemd timer case).
# If cache is stale it fetches and writes /tmp/temperature, /tmp/condition.gsm, etc.
# Run as the asterisk user so file ownership is consistent with the systemd timer.
# When already running as asterisk (cron) this is a no-op passthrough.
if ($wx eq "YES") {
    if ($> == 0) {
        system("runuser", "-u", "asterisk", "--", $wxsh, $wxid);
    } else {
        system($wxsh, $wxid);
    }
}

# ---------- Read weather data ----------
my $localwxtemp = "";
my $localfeels  = "";
my $localhumid  = "";
my $cond_word   = "";

if ($wx eq "YES") {
    if (-f "$outdir/temperature") {
        open(my $fh, '<', "$outdir/temperature") or die "Cannot open temperature: $!";
        { local $/; $localwxtemp = <$fh>; }
        close($fh);
        $localwxtemp =~ s/\s+$//;
    }

    if ($announce_feels eq "yes" && -f "$outdir/feels-like") {
        open(my $fh, '<', "$outdir/feels-like") or die "Cannot open feels-like: $!";
        { local $/; $localfeels = <$fh>; }
        close($fh);
        $localfeels =~ s/\s+$//;
    }

    if ($announce_humidity eq "yes" && -f "$outdir/humidity") {
        open(my $fh, '<', "$outdir/humidity") or die "Cannot open humidity: $!";
        { local $/; $localhumid = <$fh>; }
        close($fh);
        $localhumid =~ s/\s+$//;
    }
}

# ---------- Helpers ----------

# Add number digit files to FNAME string
sub add_number {
    my ($n, $fname_ref) = @_;
    $n = int(abs($n));
    if ($n >= 100) {
        $$fname_ref .= "$base/digits/1.gsm ";
        $$fname_ref .= "$base/digits/hundred.gsm ";
        $n -= 100 if $n > 100;
    }
    if ($n < 20) {
        $$fname_ref .= "$base/digits/$n.gsm ";
    } else {
        my $tens = substr($n, 0, 1) . "0";
        $$fname_ref .= "$base/digits/$tens.gsm ";
        my $ones = substr($n, 1, 1);
        $$fname_ref .= "$base/digits/$ones.gsm " if $ones > 0;
    }
}

# ---------- Build announcement ----------
my $FNAME = "";
my $ampm  = "PM";

my ($sec, $min, $hour, $day, $mon, $year, $wday, $yday, $isdst) = localtime;

# --- Header sound (optional) ---
my @header_exts = qw(gsm ulaw);
for my $ext (@header_exts) {
    if (-f "$confdir/saytime_header.$ext") {
        system("/usr/sbin/asterisk", "-rx",
            "rpt localplay $mynode $confdir/saytime_header");
        last;
    }
    if (-f "/etc/asterisk/local/saytime_header.$ext") {
        system("/usr/sbin/asterisk", "-rx",
            "rpt localplay $mynode /etc/asterisk/local/saytime_header");
        last;
    }
}

# --- Time announcement (skipped in Silent mode 2) ---
if ($Silent != 2) {
    if ($time_format eq "24") {
        # 24-hour format: "The time is HH MM"
        $FNAME .= "$base/the-time-is.gsm ";
        add_number($hour, \$FNAME);
        if ($min == 0) {
            $FNAME .= "$base/digits/oclock.gsm ";
        } elsif ($min < 10) {
            $FNAME .= "$base/digits/oh.gsm ";
            $FNAME .= "$base/digits/$min.gsm ";
        } else {
            my $min10 = substr($min, 0, 1) . "0";
            $FNAME .= "$base/digits/$min10.gsm ";
            my $min1 = substr($min, 1, 1);
            $FNAME .= "$base/digits/$min1.gsm " if $min1 > 0;
        }
    } else {
        # 12-hour format: "Good morning/afternoon/evening, the time is H MM AM/PM"
        if ($hour < 12) {
            $ampm  = "AM";
            $FNAME .= "$base/good-morning.gsm ";
        } elsif ($hour < 18) {
            $ampm  = "PM";
            $FNAME .= "$base/good-afternoon.gsm ";
        } else {
            $ampm  = "PM";
            $FNAME .= "$base/good-evening.gsm ";
        }

        my $hour12 = $hour;
        $hour12 -= 12 if $hour12 > 12;
        $hour12  = 12  if $hour12 == 0;

        $FNAME .= "$base/the-time-is.gsm ";
        $FNAME .= "$base/digits/$hour12.gsm ";

        if ($min != 0) {
            if ($min < 10) {
                $FNAME .= "$base/digits/oh.gsm ";
                $FNAME .= "$base/digits/$min.gsm ";
            } elsif ($min < 20) {
                $FNAME .= "$base/digits/$min.gsm ";
            } else {
                my $min10 = substr($min, 0, 1) . "0";
                $FNAME .= "$base/digits/$min10.gsm ";
                my $min1 = substr($min, 1, 1);
                $FNAME .= "$base/digits/$min1.gsm " if $min1 > 0;
            }
        }

        if ($ampm eq "AM") {
            $FNAME .= "$base/digits/a-m.gsm ";
        } else {
            $FNAME .= "$base/digits/p-m.gsm ";
        }
    }
}

# --- Weather announcement ---
if ($wx eq "YES") {
    $FNAME .= "$base/silence/1.gsm ";

    # Condition: may be one word ("clear") or two words ("partly cloudy")
    if (-e "$outdir/condition.gsm") {
        $FNAME .= "$base/weather.gsm ";
        $FNAME .= "$base/conditions.gsm ";

        # weather.sh concatenates all condition word audio into condition.gsm
        # (handles both single-word "clear" and multi-word "partly cloudy")
        $FNAME .= "$outdir/condition.gsm ";
    }

    # Temperature
    if ($localwxtemp ne "") {
        $FNAME .= "$base/wx/temperature.gsm ";

        my $temp = int($localwxtemp);
        if ($temp < -1) {
            $FNAME .= "$base/digits/minus.gsm ";
            $temp = int(abs($temp));
        }
        add_number($temp, \$FNAME);
        $FNAME .= "$base/degrees.gsm ";
    }

    # Feels-like temperature
    if ($localfeels ne "") {
        $FNAME .= "$base/silence/1.gsm ";
        # "feels like" — use wx/heat-index.gsm as "feels like" approximation,
        # or look for a feels-like.gsm if it exists
        my $feels_file = "";
        for my $dir ($base, "$base/wx") {
            if (-f "$dir/feels-like.gsm") { $feels_file = "$dir/feels-like.gsm"; last; }
        }
        $feels_file = "$base/wx/heat-index.gsm" unless $feels_file;
        $FNAME .= "$feels_file " if -f $feels_file;

        my $feels = int($localfeels);
        if ($feels < -1) {
            $FNAME .= "$base/digits/minus.gsm ";
            $feels = int(abs($feels));
        }
        add_number($feels, \$FNAME);
        $FNAME .= "$base/degrees.gsm ";
    }

    # Humidity
    if ($localhumid ne "") {
        $FNAME .= "$base/silence/1.gsm ";
        $FNAME .= "$base/wx/humidity.gsm " if -f "$base/wx/humidity.gsm";
        add_number(int($localhumid), \$FNAME);
        $FNAME .= "$base/wx/percent.gsm " if -f "$base/wx/percent.gsm";
    }
}

# ---------- Concatenate and play ----------
system("cat $FNAME > $outdir/current-time.gsm");

if ($Silent == 0) {
    system("/usr/sbin/asterisk", "-rx",
        "rpt localplay $mynode $outdir/current-time");
    sleep 5;
    unlink "$outdir/current-time.gsm";
} elsif ($Silent == 1) {
    print "\nSaved time and weather to $outdir/current-time.gsm\n\n";
} elsif ($Silent == 2) {
    print "\nSaved weather to $outdir/current-time.gsm\n\n";
}

# NOTE: /tmp/temperature, /tmp/condition.gsm, /tmp/feels-like, /tmp/humidity
# are maintained by the systemd weather timer and are intentionally NOT deleted here.

# end of saytime.pl

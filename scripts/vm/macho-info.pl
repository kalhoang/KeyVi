#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the architectures and the minimum macOS version of a Mach-O file (thin or universal), one line per
# slice: "<arch> minos <version> sdk <version>". With --archs, prints only the architectures on one line, as
# `lipo -archs` does. Needs only the system perl, so it runs in a vanilla macOS 12 VM without the command line
# tools (ADR 0315, "macOS 12 smoke test"; PLT-R105, PLT-R106).
use strict;
use warnings;

my $archs_only = 0;
if (@ARGV && $ARGV[0] eq '--archs') {
    $archs_only = 1;
    shift @ARGV;
}
my $path = shift @ARGV or die "usage: macho-info.pl [--archs] FILE\n";
open(my $fh, '<:raw', $path) or die "cannot open $path: $!\n";
my $file_size = -s $fh;

sub read_at {
    my ($offset, $length) = @_;
    die "not a Mach-O file (truncated): $path\n" if $offset + $length > $file_size;
    seek($fh, $offset, 0) or die "seek failed: $!\n";
    my $buffer = '';
    my $got = read($fh, $buffer, $length);
    die "not a Mach-O file (short read): $path\n" unless defined $got && $got == $length;
    return $buffer;
}

sub version_string {
    my ($value) = @_;
    my ($major, $minor, $patch) = ($value >> 16, ($value >> 8) & 0xff, $value & 0xff);
    return $patch ? "$major.$minor.$patch" : "$major.$minor";
}

my %cpu_names = (0x01000007 => 'x86_64', 0x0100000c => 'arm64', 7 => 'i386', 12 => 'arm');
my @offsets;
die "not a Mach-O file (empty): $path\n" if $file_size < 4;
my $magic = unpack('N', read_at(0, 4));
if ($magic == 0xcafebabe || $magic == 0xcafebabf) {
    my $count = unpack('N', read_at(4, 4));
    die "not a Mach-O file (implausible universal header): $path\n" if $count < 1 || $count > 16;
    for my $index (0 .. $count - 1) {
        if ($magic == 0xcafebabe) {
            my (undef, undef, $offset) = unpack('N3', read_at(8 + 20 * $index, 20));
            push @offsets, $offset;
        } else {
            my (undef, undef, $high, $low) = unpack('N4', read_at(8 + 32 * $index, 32));
            push @offsets, $high * 4294967296 + $low;
        }
    }
} else {
    push @offsets, 0;
}

my @slices;
for my $offset (@offsets) {
    my ($slice_magic, $cpu_type, $cpu_subtype, undef, $command_count) = unpack('V5', read_at($offset, 20));
    die "not a 64-bit Mach-O slice at offset $offset: $path\n" unless $slice_magic == 0xfeedfacf;
    my $name = $cpu_names{$cpu_type} // sprintf('cpu-0x%x', $cpu_type);
    my $subtype = $cpu_subtype & 0x00ffffff;
    $name = 'arm64e' if $name eq 'arm64' && $subtype == 2;
    $name = 'x86_64h' if $name eq 'x86_64' && $subtype == 8;
    my ($minos, $sdk) = ('unknown', 'unknown');
    my $command_offset = $offset + 32;
    for (1 .. $command_count) {
        my ($command, $size) = unpack('V2', read_at($command_offset, 8));
        die "not a Mach-O file (bad load command size): $path\n" if $size < 8;
        if ($command == 0x32) {    # LC_BUILD_VERSION: platform, minos, sdk
            my (undef, undef, undef, $min, $kit) = unpack('V5', read_at($command_offset, 20));
            ($minos, $sdk) = (version_string($min), version_string($kit));
        } elsif ($command == 0x24) {    # LC_VERSION_MIN_MACOSX: version, sdk
            my (undef, undef, $min, $kit) = unpack('V4', read_at($command_offset, 16));
            ($minos, $sdk) = (version_string($min), version_string($kit));
        }
        $command_offset += $size;
    }
    push @slices, [$name, $minos, $sdk];
}

if ($archs_only) {
    print join(' ', map { $_->[0] } @slices), "\n";
} else {
    printf("%s minos %s sdk %s\n", @$_) for @slices;
}

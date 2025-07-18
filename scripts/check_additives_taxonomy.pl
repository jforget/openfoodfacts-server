#!/usr/bin/perl

use Modern::Perl '2017';

use Data::Dumper;

#11872 Use PO Storable

use Storable qw(lock_store lock_nstore lock_retrieve);

sub retrieve {
	my $file = shift @_;
	# If the file does not exist, return undef.
	if (!-e $file) {
		return;
	}
	return lock_retrieve($file);
}

print $ARGV[0];

my $ref = retrieve($ARGV[0]);

foreach my $lc (sort keys %{$ref->{synonyms_for}}) {

	foreach my $additive (sort keys %{$ref->{synonyms_for}{$lc}}) {
		if (scalar @{$ref->{synonyms_for}{$lc}{$additive}} < 2) {
			print "$lc - $additive has no name - " . (scalar @{$ref->{synonyms_for}{$lc}{$additive}}) . "\n";
		}
	}
}

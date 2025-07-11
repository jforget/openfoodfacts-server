#!/usr/bin/perl

use Modern::Perl '2017';
use utf8;

use CGI::Carp qw(fatalsToBrowser);

use ProductOpener::Config qw/:all/;
use ProductOpener::Paths qw/:all/;
use ProductOpener::Store qw/:all/;
use ProductOpener::Products qw/:all/;

use CGI qw/:cgi :form escapeHTML/;
use URI::Escape::XS;
use Storable qw/dclone/;
use Encode;
use JSON::MaybeXS;

use Data::Dumper;

# Get a list of all products

use Getopt::Long;

my @products = ();

GetOptions('products=s' => \@products);
@products = split(/,/, join(',', @products));

sub find_products($) {

	my $dir = shift;

	my $next = product_iter($dir);
	while (my $file = $next->()) {
		push @products, product_id_from_path($file);
	}

	return;
}

if (scalar $#products < 0) {
	find_products($BASE_DIRS{PRODUCTS});
}

# Create directory to move old images to
(-e "$www_root/old-images") or mkdir("$www_root/old-images", 0755);
(-e "$www_root/old-images/products") or mkdir("$www_root/old-images/products", 0755);

my $count = $#products;
my $i = 0;
my $images_deleted = 0;

my %codes = ();

print STDERR "$count products to update\n";

foreach my $code (@products) {

	$i++;

	#next if ($code ne "4072700318675");

	my $path = product_path($code);

	my $product_ref = retrieve_object("$BASE_DIRS{PRODUCTS}/$path/product")
		or print "not defined $BASE_DIRS{PRODUCTS}/$path/product\n";

	if ((defined $product_ref)) {

		my $dir = "$BASE_DIRS{PRODUCTS_IMAGES}/$path";

		# Store the highest version number for each imageid

		my %highest_version = ();

		# Go through all images a 1st time to get the highest version for each imageid

		next if !-e $dir;

		print STDERR "\nproduct code: $code - path: $path\n";

		opendir DH, "$dir" or die "could not open image dir: $dir directory: $!\n";
		foreach my $file (sort readdir(DH)) {
			chomp($file);
			next if ($file !~ /\.jpg$/);

			if ($file =~ /^((front|ingredients|nutrition)(_\w\w)?)\.(\d+)\.full.jpg$/) {
				my $imageid = $1;
				my $version = $4;

				print STDERR "1st pass: $file - id: $imageid - v: $version\n";

				defined $highest_version{$imageid} or $highest_version{$imageid} = 0;
				if ($version > $highest_version{$imageid}) {
					$highest_version{$imageid} = $version;
					print STDERR "new highest version for id: $imageid - version: $version\n";
				}
			}
		}
		closedir DH;

		# Go through all images a 2nd time to delete images that have a lower version number

		opendir DH, "$dir" or die "could not open image dir: $dir directory: $!\n";
		foreach my $file (sort readdir(DH)) {
			chomp($file);
			next if ($file !~ /\.jpg$/);

			if ($file =~ /^((front|ingredients|nutrition)(_\w\w)?)\.(\d+)\.(\w+)\.jpg$/) {
				my $imageid = $1;
				my $version = $4;

				print STDERR "2nd pass: $file - id: $imageid - v: $version - highest: $highest_version{$imageid}\n";

				if ($version < $highest_version{$imageid}) {
					print STDERR "moving imageid: $imageid - version: $version\n";
					print STDERR "mv $dir/$file $www_root/old-images/products/$path/\n";

					# Create the directories for the product
					my $current_dir = "$www_root/old-images/products";
					foreach my $component (split("/", $path)) {
						$current_dir .= "/$component";
						(-e $current_dir) or mkdir($current_dir, 0755);
					}

					require File::Copy;
					File::Copy::move("$dir/$file", "$www_root/old-images/products/$path/")
						or die("could not move: $!\n");

					$images_deleted++;
				}
			}
		}
		closedir DH;
		#($images_deleted > 10) and last;
	}
}

print STDERR "$i products - $images_deleted images moved\n";

exit(0);


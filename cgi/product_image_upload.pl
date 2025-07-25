#!/usr/bin/perl -w

# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2023 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use ProductOpener::PerlStandards;

use CGI::Carp qw(fatalsToBrowser);

use ProductOpener::Config qw/:all/;
use ProductOpener::Paths qw/%BASE_DIRS ensure_dir_created/;
use ProductOpener::Store qw/get_string_id_for_lang/;
use ProductOpener::Index qw/:all/;
use ProductOpener::Display qw/:all/;
use ProductOpener::HTTP qw/single_param/;
use ProductOpener::Lang qw/$lc lang/;
use ProductOpener::Tags qw/:all/;
use ProductOpener::Users qw/$Org_id $Owner_id $User_id %User/;
use ProductOpener::Images
	qw/get_code_and_imagefield_from_file_name is_protected_image process_image_crop process_image_upload scan_code $valid_image_types_regexp/;
use ProductOpener::Products qw/:all/;
use ProductOpener::Text qw/remove_tags_and_quote/;
use ProductOpener::APIProductWrite qw/:all/;
use ProductOpener::HTTP qw/write_cors_headers/;

use CGI qw/:cgi :form escapeHTML/;
use URI::Escape::XS;
use Storable qw/dclone/;
use Encode;
use JSON::MaybeXS;
use Log::Any qw($log);
use Data::DeepAccess qw(deep_exists deep_get deep_set);

my $type = single_param('type') || 'add';
my $action = single_param('action') || 'display';
my $code = normalize_code(single_param('code'));
# For scan parties, we may get photos in sequence, with the barcode only in the first photo
my $previous_code = normalize_code(single_param('previous_code'));
my $previous_imgid = single_param('previous_imgid');
my $imagefield = single_param('imagefield');
my $delete = single_param('delete');

local $log->context->{upload_session} = int(rand(100000000));

$log->debug("start", {ip => remote_addr(), type => $type, action => $action, code => $code}) if $log->is_debug();

my $env = $ENV{QUERY_STRING};

$log->debug("calling init()", {query_string => $env});

my $request_ref = ProductOpener::Display::init_request();

$log->debug(
	"parsing code",
	{
		subdomain => $subdomain,
		original_subdomain => $original_subdomain,
		user => $User_id,
		code => $code,
		previous_code => $previous_code,
		previous_imgid => $previous_imgid,
		cc => $request_ref->{cc},
		lc => $lc,
		imagefield => $imagefield,
		ip => remote_addr()
	}
) if $log->is_debug();

write_cors_headers();

# By default, don't select images uploaded (e.g. through the product edit form)

my $select_image = 0;

# Producers platform: the input file name is files[]
# If no code and imagefield is passed, try to guess it from the filename

my $code_specified = 1;
my $filename;
my $tmp_filename;

my $using_previous_code;
my $scanned_code;
my $code_from_file_name;

if (not defined $code) {

	$code_specified = 0;

	my $file = single_param("files[]");
	$filename = $file . "";

	($code, $imagefield) = get_code_and_imagefield_from_file_name($lc, $filename);

	if ($code) {
		$code_from_file_name = $code;
	}
	else {

		if ($file =~ /\.(gif|jpeg|jpg|png|heic)$/i) {

			$log->debug("scan barcode in image file", {file => $file}) if $log->is_debug();

			my $extension = lc($1);
			$tmp_filename = get_string_id_for_lang("no_language", remote_addr() . '_' . $`);

			ensure_dir_created($BASE_DIRS{CACHE_TMP}) or display_error_and_exit($request_ref, "Missing path", 503);
			open(my $out, ">", "$BASE_DIRS{CACHE_TMP}/$tmp_filename.$extension");
			while (my $chunk = <$file>) {
				print $out $chunk;
			}
			close($out);

			$code = scan_code("$BASE_DIRS{CACHE_TMP}/$tmp_filename.$extension");
			if (defined $code) {
				$code = normalize_code($code);
				$scanned_code = $code;
			}
			$tmp_filename = "$BASE_DIRS{CACHE_TMP}/$tmp_filename.$extension";
		}

		# If we have a previous code, use it
		if ((not $code) and (defined $previous_code)) {
			$log->debug("no barcode found in image file, using previous code", {previous_code => $previous_code})
				if $log->is_debug();
			$code = $previous_code;
			$using_previous_code = $previous_code;
		}
	}

	if ($code) {
		if ((defined $imagefield) and ($imagefield !~ /\//) and ($imagefield !~ /^other/)) {
			$select_image = 1;
		}
	}
}

my $response_ref = {
	files => [
		{
			filename => $filename . "",    # Make filename a scalar
		}
	],
};

if ((not defined $code) or ($code eq '')) {

	$log->warn("no code");
	$response_ref->{status} = 'status not ok';
	$response_ref->{error} = lang("image_upload_error_no_barcode_specified_or_found");
	if (not $code_specified) {
		# for jquery.fileupload-ui.js
		$response_ref->{files}[0]{error} = $response_ref->{error};
	}
	my $data = encode_json($response_ref);
	print header(-type => 'application/json', -charset => 'utf-8') . $data;
	exit(0);
}

$response_ref->{code} = $code;

my $product_id = product_id_for_owner($Owner_id, $code);

my $interface_version = '20120622';

# Check that the image directory exists
ensure_dir_created($BASE_DIRS{PRODUCTS_IMAGES}) or display_error_and_exit($request_ref, "Missing path", 503);

if ($imagefield) {

	$response_ref->{imagefield} = $imagefield;

	my $path = product_path_from_id($product_id);

	$log->debug("path determined", {imagefield => $imagefield, path => $path, delete => $delete});

	if ($path eq 'invalid') {
		# non numeric code was given
		$log->warn("no code", {code => $code});
		$response_ref->{status} = 'status not ok';
		$response_ref->{error} = "error - invalid product code: $code";
		$response_ref->{files}[0]{error} = $response_ref->{error};
		my $data = encode_json($response_ref);
		print header(-type => 'application/json', -charset => 'utf-8') . $data;
		exit(0);
	}

	my $product_ref = retrieve_product($product_id);

	if (not $product_ref) {
		$log->info("product code does not exist yet, creating product", {code => $code});
		$product_ref = init_product($User_id, $Org_id, $code, $country);
		$product_ref->{interface_version_created} = $interface_version;
		$product_ref->{lc} = $lc;
		store_product($User_id, $product_ref, "Creating product (image upload)");
	}
	else {
		$log->info("product code already exists", {code => $code});
	}

	my $product_name = remove_tags_and_quote(product_name_brand_quantity($product_ref));
	if ((not defined $product_name) or ($product_name eq "")) {
		$product_name = $code;
	}

	my $product_url = product_url($product_ref);

	$response_ref->{files}[0]{url} = $product_url;
	$response_ref->{files}[0]{name} = $product_name;

	# Some apps may be passing a full locale like imagefield=front_pt-BR
	$imagefield =~ s/^($valid_image_types_regexp)_(\w\w)-.*/$1_$2/;

	# For apps that do not specify the language associated with the image, try to assign one
	if ($imagefield =~ /^($valid_image_types_regexp)$/) {
		# If the product exists, use the main language of the product
		# otherwise if the product was just created above, we will get the current $lc
		$imagefield .= "_" . $product_ref->{lc};
	}

	$response_ref->{imagefield} = $imagefield;

	my $imgid;
	my $debug_string;

	my $imagefield_or_filename = $imagefield;
	(defined $tmp_filename) and $imagefield_or_filename = $tmp_filename;

	my $imgid_returncode
		= process_image_upload($product_ref, $imagefield_or_filename, $User_id, time(), "image upload", \$imgid,
		\$debug_string);

	$log->debug(
		"after process_image_upload",
		{
			imgid => $imgid,
			imagefield => $imagefield,
			imgid_returncode => $imgid_returncode,
			debug_string => $debug_string
		}
	) if $log->is_debug();

	# For backwards compatibility, if we have no imgid (if the image was not uploaded), we return the return code in the imgid field
	$response_ref->{imgid} = $imgid || $imgid_returncode;
	if ($imgid > 0) {
		$response_ref->{files}[0]{thumbnailUrl} = "/images/products/$path/$imgid.$thumb_size.jpg";
	}

	if ($imgid_returncode < 0) {
		# Error during upload
		$response_ref->{status} = 'status not ok';
		$response_ref->{error} = "error";
		($imgid_returncode == -2) and $response_ref->{error} = "field imgupload_$imagefield not set";
		($imgid_returncode == -3) and $response_ref->{error} = lang("image_upload_error_image_already_exists");
		($imgid_returncode == -4) and $response_ref->{error} = lang("image_upload_error_image_too_small");
		($imgid_returncode == -5) and $response_ref->{error} = lang("image_upload_error_could_not_read_image");

		if (not $code_specified) {
			# for jquery.fileupload-ui.js
			if ($imgid_returncode == -3) {
				$response_ref->{files}[0]{info} = $response_ref->{error};
			}
			else {
				$response_ref->{files}[0]{error} = $response_ref->{error};
			}
		}

		if (defined $debug_string) {
			$response_ref->{debug} = $debug_string;
		}
	}
	else {
		# Image uploaded successfully

		my $image_data_ref = {
			imgid => $imgid,
			thumb_url => "$imgid.${thumb_size}.jpg",
			crop_url => "$imgid.${crop_size}.jpg",
		};

		if ($User{moderator}) {
			$product_ref = retrieve_product($product_id);
			$image_data_ref->{uploader} = $product_ref->{images}{uploaded}{$imgid}{uploader};
			$image_data_ref->{uploaded} = display_date($product_ref->{images}{uploaded}{$imgid}{uploaded_t});
		}

		my $product_name = remove_tags_and_quote(product_name_brand_quantity($product_ref));
		if ((not defined $product_name) or ($product_name eq "")) {
			$product_name = $code;
		}

		my $product_url = product_url($product_ref);

		$response_ref->{status} = 'status ok';
		$response_ref->{image} = $image_data_ref;

		# Select the image
		if ($imagefield =~ /^($valid_image_types_regexp)_(\w\w)$/) {

			my $image_type = $1;
			my $image_lc = $2;
			# Changed 2020-03-05: overwrite already selected images
			# Changed 2020-04-20: don't overwrite selected images if the source is the product edit form
			if (
				(
					   (not defined single_param('source'))
					or (single_param('source') ne "product_edit_form")
					or (not deep_exists($product_ref, "images", "selected", $image_type, $image_lc))
				)
				and (not is_protected_image($product_ref, $image_type, $image_lc) or $User{moderator})

				)
			{
				$log->debug("selecting image", {imgid => $imgid, image_type => $image_type, lc => $image_lc})
					if $log->is_debug();
				process_image_crop($User_id, $product_ref, $image_type, $image_lc, $imgid, undef);
			}
		}
		# If the image type is "other" and we don't have a front image, assign it
		# This is in particular for producers that send us many images without specifying their type: assume the first one is the front
		elsif (
			($imagefield =~ /^other/)
			and (
				(not deep_exists($product_ref, "images", "selected", "front", $product_ref->{lc}))
				or (    (defined $previous_imgid)
					and ($previous_imgid eq $product_ref->{images}{selected}{"front"}{$product_ref->{lc}}{imgid}))
			)
			)
		{
			$log->debug(
				"selecting front image as we don't have one",
				{
					imgid => $imgid,
					previous_imgid => $previous_imgid,
					imagefield => $imagefield,
					front_imagefield => "front_" . $product_ref->{lc}
				}
			) if $log->is_debug();
			process_image_crop($User_id, $product_ref, "front", $product_ref->{lc}, $imgid, undef);
		}
	}

	(defined $code) and $response_ref->{files}[0]{code} = $code;
	(defined $code_from_file_name) and $response_ref->{files}[0]{code_from_file_name} = $code_from_file_name;
	(defined $scanned_code) and $response_ref->{files}[0]{scanned_code} = $scanned_code;
	(defined $using_previous_code) and $response_ref->{files}[0]{using_previous_code} = $using_previous_code;

	my $data = encode_json($response_ref);

	$log->debug("JSON data output", {data => $data}) if $log->is_debug();

	print header(-type => 'application/json', -charset => 'utf-8') . $data;

}
else {

	$log->warn("no image field defined");
	$response_ref->{status} = 'status not ok';
	$response_ref->{error} = "error - imagefield not defined";
	my $data = encode_json($response_ref);
	print header(-type => 'application/json', -charset => 'utf-8') . $data;
}

exit(0);


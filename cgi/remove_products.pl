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

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

use CGI::Carp qw(fatalsToBrowser);

use ProductOpener::Config qw/:all/;
use ProductOpener::Paths qw/%BASE_DIRS ensure_dir_created/;
use ProductOpener::Store qw/:all/;
use ProductOpener::Display qw/:all/;
use ProductOpener::Users qw/$Owner_id/;
use ProductOpener::Lang qw/lang/;
use ProductOpener::Mail qw/:all/;
use ProductOpener::Producers qw/:all/;
use ProductOpener::Data qw/get_products_collection/;
use ProductOpener::HTTP qw/single_param/;

use Apache2::RequestRec ();
use Apache2::Const ();

use CGI qw/:cgi :form escapeHTML :cgi-lib/;
use URI::Escape::XS;
use Log::Any qw($log);

my $request_ref = ProductOpener::Display::init_request();

my $action = single_param('action') || 'display';

my $title = lang("remove_products_from_producers_platform");
my $html = '';
my $template_data_ref = {};

$template_data_ref->{action} = $action;

if (not $server_options{producers_platform}) {
	display_error_and_exit($request_ref, lang("function_not_available"), 200);
}

if ((not defined $Owner_id) or ($Owner_id !~ /^(user|org)-\S+$/)) {
	display_error_and_exit($request_ref, lang("no_owner_defined"), 200);
}

if ($action eq "display") {

	my $confirm = lang("remove_products_confirm");
	$confirm =~ s/'/\'/g;

	$template_data_ref->{confirm_alert} = $confirm;

}

elsif ($action eq "process") {

	$log->debug("Deleting products for owner in mongodb", {owner => $Owner_id}) if $log->is_debug();

	my $products_collection = get_products_collection();
	$products_collection->delete_many({"owner" => $Owner_id});

	require File::Copy::Recursive;
	File::Copy::Recursive->import(qw( dirmove ));

	my $deleted_dir = $BASE_DIRS{DELETED_PRIVATE_PRODUCTS} . "/" . $Owner_id . "." . time();
	ensure_dir_created($BASE_DIRS{PRODUCTS_IMAGES}) or display_error_and_exit($request_ref, "Missing path", 503);

	$log->debug("Moving data to deleted dir", {owner => $Owner_id, deleted_dir => $deleted_dir}) if $log->is_debug();

	dirmove("$BASE_DIRS{IMPORT_FILES}/$Owner_id", "$deleted_dir/import_files")
		or print STDERR "Could not move $BASE_DIRS{IMPORT_FILES}/$Owner_id to $deleted_dir/import_files : $!\n";
	dirmove("$BASE_DIRS{EXPORT_FILES}/$Owner_id", "$deleted_dir/export_files")
		or print STDERR "Could not move $BASE_DIRS{EXPORT_FILES}/$Owner_id to $deleted_dir/export_files : $!\n";
	move_object("$BASE_DIRS{PRODUCTS}/$Owner_id", "$deleted_dir/products");
	dirmove("$BASE_DIRS{PRODUCTS_IMAGES}/$Owner_id", "$deleted_dir/images")
		or print STDERR "Could not move $BASE_DIRS{PRODUCTS_IMAGES}/$Owner_id to $deleted_dir/images : $!\n";

}

process_template('web/pages/remove_products/remove_products.tt.html', $template_data_ref, \$html)
	or $html = "<p>" . $tt->error() . "</p>";

$request_ref->{title} = $title;
$request_ref->{content_ref} = \$html;
display_page($request_ref);

exit(0);


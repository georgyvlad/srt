#!/usr/bin/perl -w

# This web-based tool is intended for performing final touchup on an SRT file. Touchup actions
# will be added as necessary. For now, we only have one - strip trailing commas.
#
# Original author: Georgy Vladimirov
#
# The work is volunteered contribution to the Zeitgeist Movement (http://www.thezeitgeistmovement.com)
# It is Open Source and licenced as the Perl language itself (under the Artistic Licence and the
# GNU General Public Licence).

use strict;

use CGI;
use CGI::Carp qw(fatalsToBrowser);

use lib '.';
use SRT;

my $q = CGI->new;
my $p = $q->Vars;

my ($fh1, $fn1, $srt1);

my $encoding = $p->{'encoding'};
$encoding = 'utf8'  unless ( $encoding );		# 'iso-8859-1', 'utf8'

# create an object of the module SRT, which does a lot of common functionality
my $so = SRT->new( $q, $encoding );

# user submits SRT file
if ( $p->{'file1'} )
{
	&check_input_file();

	$srt1 = $so->parse_file( \*$fh1 );

	&export_touchup_result();
}
else
{
	&print_file_form();
}


#----------------- SUBS -----------------

sub check_input_file
{
	$fh1 = $q->upload( 'file1' );
	$fh1 = $so->cgi_to_file_handle( $fh1 )  if ( defined $fh1 );
	$so->error( "File1 can't be read." )  unless ( defined $fh1 );
	$fn1 = $p->{'file1'};
	$fn1 =~ s/\n//g;
}

sub print_file_form
{
	print $q->header( -type => 'text/html', -charset => $encoding );
	print $q->start_html( 'Zeitgeist Movement | SRT | touchup' );
	print "<body>\n";
	$so->print_tools_menu();
	print "<h1>Touchup SRT</h1>\n";

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print 'SRT File: ', $q->filefield( 'file1', '', 75, 200 ), "<br>\n";
	print "<h3>Touchup actions:</h3>";
	print '<input type="checkbox" name="strip_comma" value="42">',
		"&nbsp; Remove commas that are at end of subtitles.<br><br>\n";

	print "Select the final touchup actions you want to perform on the SRT file and click<br>
		'Perform Touchup'. The resulting SRT file will come back and your browser should<br>
		prompt you to save it.<br><br>\n";
	print $q->submit( 'submit', 'Perform Touchup' ), "<br>\n";
	print $q->end_form;

	print "</body>";
	print $q->end_html;
}

sub export_touchup_result
{
	my $file_txt = '';

	# go over each subtitle and apply touchup actions
	foreach my $s ( @$srt1 )
	{
		if ( $p->{'strip_comma'} )
		{
			$s->{'txt'} =~ s/,$//s;
		}

		# keep accumulating the file contents
		$file_txt .= "$s->{'c'}\n$s->{'t'}\n$s->{'txt'}\n\n";
	}

	my $filename = $fn1;
	if ( $filename =~ /\.srt$/i ) {
		$filename =~ s/\.srt/.touchup.srt/i;
	} else {
		$filename .= '.touchup.srt';
	}

	print $q->header(
		-type       => 'text/plain',
		-charset    => $encoding,
		-attachment => $filename
	);
	print $file_txt;
}

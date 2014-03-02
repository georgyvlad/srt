#!/usr/bin/perl -w

# This web-based tool is intended for analyzing and adjusting the subtitles' fragmentation
# inside two SRT (movie subtitles) files that are very similar. The files are usually two
# versions of the same video (timestamps are identical) with very small differences.
# The first SRT file serves as the base for comparison, and the second will be compared
# and adjusted. We are looking for places where the two files differ in the way subtitles
# were fragmented. When we find a place where the fragmentation differs, we show the fragment
# with its text and the way it is broken up in the base file. We also give a few text
# boxes to the user to allow him to split the file2 text into the same subtitles. The
# process will be repeated until the two files' subtitles and timestamps are fragmented
# identically. An extra step "Synchronize Timestamps" synchronizes any possible remaining
# timestamp differences.
# At the end, the user can export the synchronized file2 to his computer.
# The script keeps all its data in a data directory, which is by default the current directory
# where the script is running. If the directory doesn't exist, it will attempt to create it.
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

my $data_dir = 'data_frag/';
# once in so many requests (on average), we try to clean up
my $cleanup_request_freq = 100;
# range for random number used for automatic project name
my $project_random_range = 10_000;
# age for data files when they become deletable
my $max_datafile_age = ( 60 * 24 * 60 * 60 );	# 60 days ago
# margin (in milliseconds) for considering timestamps equal
my $eq_margin = 600;

my $q = CGI->new;
my $p = $q->Vars;

my ($fh1, $fh2, $fn1, $fn2, $srt1, $srt2, $s_start, $section_srts1, $section_srts2, $project);

my $encoding = $p->{'encoding'};
$encoding = 'utf8'  unless ( $encoding );		# 'iso-8859-1', 'utf8'

# make sure our data dir exists and try to create it otherwise
mkdir $data_dir  unless ( -d $data_dir );

# create an object of the module SRT, which does a lot of common functionality
my $so = SRT->new( $q, $encoding, $data_dir, $project_random_range, $max_datafile_age );

# once in a while, spend some time cleaning up
$so->cleanup_project_data_files()  if ( int( rand( $cleanup_request_freq ) ) == 1 );

# the export happens before we print the header, so it can print its own
if ( $p->{'step'} and $p->{'step'} eq 'export' )
{
	$project = $p->{'project'};
	$so->error( 'No project specified for the export.', 1 )  unless ( $project );

	&read_project_meta_file();

	&export_refragmented_file();

	exit;
}


print $q->header( -type => 'text/html', -charset => $encoding );
print $q->start_html( 'Zeitgeist Movement | SRT | frag' );

# user wants to synchronize the timestamps between the two files
if ( $p->{'step'} and $p->{'step'} eq 'sync' )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&parse_files();

	&synchronize_timestamps();

	&print_sync_form();
}
# user submits his refragmentation input
elsif ( $p->{'step'} and $p->{'step'} eq 'refragment' )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&parse_files();

	&refragment();

	&find_fragmentation_diff();

	&print_refragment_form();
}
# user wants to work on existing project
elsif ( $p->{'project'} )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&parse_files();

	&find_fragmentation_diff();

	&print_refragment_form();
}
# user submits SRT files for the first time (project will be created)
elsif ( $p->{'file1'} )
{
	&check_input_files();

	# automatically create project name/number the first time files are submitted
	$project = $so->get_new_project_name();

	&submit_and_parse_files( $project );

	&find_fragmentation_diff();

	&print_refragment_form();
}
else
{
	&print_file_form();
}

print $q->end_html;


#----------------- SUBS -----------------

sub check_input_files
{
	$fh1 = $q->upload( 'file1' );
	$fh1 = $so->cgi_to_file_handle( $fh1 )  if ( defined $fh1 );
	$so->error( "'Reference SRT' file can't be read." )  unless ( defined $fh1 );
	$fn1 = $p->{'file1'};
	$fn1 =~ s/\n//g;

	$fh2 = $q->upload( 'file2' );
	$fh2 = $so->cgi_to_file_handle( $fh2 )  if ( defined $fh2 );
	$so->error( "'Refragment SRT' file can't be read." )  unless ( defined $fh2 );
	$fn2 = $p->{'file2'};
	$fn2 =~ s/\n//g;
}

sub submit_and_parse_files
{
	my $df1 = "${data_dir}${project}_file1.srt";
	my $dfh1;
	open( $dfh1, ">", $df1 )  or $so->error( "Can't save 'Reference SRT' file: $!\n" );
	my $df2 = "${data_dir}${project}_file2.srt";
	my $dfh2;
	open( $dfh2, ">", $df2 )  or $so->error( "Can't save 'Refragment SRT' file: $!\n" );

	$srt1 = $so->parse_file( \*$fh1, $dfh1 );
	$srt2 = $so->parse_file( \*$fh2, $dfh2 );

	&save_project_meta_file();
}

sub parse_files
{
	my $df1 = "${data_dir}${project}_file1.srt";
	open( $fh1, "<", $df1 )  or $so->error( "Can't open 'Reference SRT' file: $!\n" );
	my $df2 = "${data_dir}${project}_file2.srt";
	open( $fh2, "<", $df2 )  or $so->error( "Can't open 'Refragment SRT' file: $!\n" );

	$srt1 = $so->parse_file( $fh1 );
	$srt2 = $so->parse_file( $fh2 );

	# it's important that we have the order field set properly for our subtitles/srts
	$so->renumber_srts_order( $srt1 );
	$so->renumber_srts_order( $srt2 );
}

# returns the contents of file2 (the 'Refragment SRT' file)
sub read_file2
{
	my ($content_ref) = @_;

	my $df2 = "${data_dir}${project}_file2.srt";
	open( $fh2, "<", $df2 )  or $so->error( "Can't open 'Refragment SRT' file: $!\n" );
	binmode $fh2;
	local $/ = undef;
	$$content_ref = <$fh2>;
	close( $fh2 );
}

# takes the $srt2 array in memory and saves it to file2 (the 'Refragment SRT' file)
sub save_file2
{
	my $df2 = "${data_dir}${project}_file2.srt";

	open( $fh2, ">", $df2 )  or $so->error( "Can't save 'Refragment SRT' file: $!\n" );
	binmode $fh2;

	foreach my $s ( @$srt2 )
	{
		print $fh2 "$s->{'c'}\n$s->{'t'}\n$s->{'txt'}\n\n";
	}
	close $fh2;
}

sub save_project_meta_file
{
	my $mf = $so->meta_file_name( $project );
	my $mfh;
	open( $mfh, ">", $mf )  or $so->error( "Can't save project meta file: $!\n" );
	print $mfh "file1=$fn1\n", "file2=$fn2\n";
	close $mfh;
}

sub read_project_meta_file
{
	my $mf = $so->meta_file_name( $project );
	$so->error( "Project ($project) does not exist.\n" )  unless ( -f $mf );

	my $mfh;
	open( $mfh, "<", $mf )  or $so->error( "Can't open project meta file: $!\n" );
	$fn1 = <$mfh>;
	$fn1 = $1  if ( $fn1 =~ /^file1=(.*)/m );
	$fn2 = <$mfh>;
	$fn2 = $1  if ( $fn2 =~ /^file2=(.*)/m );
	close $mfh;
}

sub refragment
{
	# grab the submitted fragments and create srt records out of them
	my @frag_srts =
		map { { 'c' => $_, 'txt' => $p->{"fragment_$_"} } }
		sort { $a <=> $b }
		map { /fragment_(\d+)/; $1 }
		grep { /fragment_\d+/ }
		keys %$p;

	return unless ( @frag_srts > 0 );

	# strip out leading and trailing whitespace from the fragments
	$so->trim( $_->{'txt'} )  foreach ( @frag_srts );

	my $last_index;

	# if the 'Reference SRT' file has more subtitles at the end, just add them
	if ( $p->{'section_start'} >= @$srt2 )
	{
		push @$srt2, @frag_srts;
		$last_index = scalar @$srt2 - 1;
	}
	# we start the refragmentation within the size of the 'Refragment SRT' array
	else
	{
		# calculate the index for the last of the fragments about to become newly inserted srts
		$last_index = $p->{'section_start'} + @frag_srts - 1;
		$last_index = 0  if ( $last_index < 0 );

		# replace the old srts with the new fragmentation srts
		splice( @$srt2, $p->{'section_start'}, $p->{'section_size'}, @frag_srts );
	}

	# copy over timestamps from 'Reference SRT' to the 'Refragment SRT' file
	# (up to the last newly inserted, new fragmentation srt)
	for ( my $i = 0; $i <= $last_index; $i++ )
	{
		$srt2->[$i]{'t'} = $srt1->[$i]{'t'};
	}

	# renumber the order field for the srts in the 'Refragment SRT' file
	$so->renumber_srts_order( $srt2 );

	# save the srts from memory into file
	&save_file2();
}

sub synchronize_timestamps
{
	# copy over timestamps from 'Reference SRT' to the 'Refragment SRT' file
	for ( my $i = 0; $i < @$srt1; $i++ )
	{
		# if the 'Reference SRT' file has more subtitles than the 'Refragment SRT' file,
		# we don't want to do anything more
		# NOTE: we can, instead, expand the 'Refragment SRT' file and copy over the extra srts
		if ( $i >= @$srt2 )
		{
			last;
#			$srt2->[$i]{'c'} = $srt1->[$i]{'c'};
#			$srt2->[$i]{'txt'} = $srt1->[$i]{'txt'};
		}

		$srt2->[$i]{'t'} = $srt1->[$i]{'t'};
	}

	# save the srts from memory into file
	&save_file2();
}

# finds the first section of subtitles that seems fragmented differently in file2
sub find_fragmentation_diff
{
	$section_srts1 = [];
	$section_srts2 = [];
	$s_start = 0;

	# our 'Reference SRT' file has no subtitles
	unless ( defined $srt1 and ref( $srt1 ) eq 'ARRAY' and @$srt1 > 0 )
	{
		@$section_srts2 = (@$srt2)  if ( defined $srt2 and ref( $srt2 ) eq 'ARRAY' );
	}

	# our 'Refragment SRT' file has no subtitles
	unless ( defined $srt2 and ref( $srt2 ) eq 'ARRAY' and @$srt2 > 0 )
	{
		@$section_srts1 = (@$srt1)  if ( defined $srt1 and ref( $srt1 ) eq 'ARRAY' );
	}

	my $started = 0;
	my $i1 = 0;
	my $i2 = 0;

	# iterate the two SRT's in parallel and look for a section of differing fragmentation
	while ( $i1 < @$srt1 or $i2 < @$srt2 )
	{
		# the 'Reference SRT' has run out of subtitles
		if ( $i1 >= @$srt1 )
		{
			$s_start = $i2  unless ( $started );

			# grab the rest of the subtitles from the 'Refragment SRT' file and exit the loop
			push @$section_srts2, (@$srt2)[ $i2 .. (scalar @$srt2 - 1) ];
			last;
		}

		# the 'Refragment SRT' has run out of subtitles
		if ( $i2 >= @$srt2 )
		{
			$s_start = $i1  unless ( $started );

			# grab the rest of the subtitles from the 'Reference SRT' file and exit the loop
			push @$section_srts1, (@$srt1)[ $i1 .. (scalar @$srt1 - 1) ];
			last;
		}

		my $s1 = $srt1->[$i1];
		my $s2 = $srt2->[$i2];

		# get timestamps for the subtitle from the 'Reference SRT' file
		my ($s1_st, $s1_end) = $so->get_start_end( $s1->{'t'} );
		$so->error("'Reference SRT' file has bad timestamps for subtitle: $s1->{'c'} - $s1->{'txt'}")
			unless ( defined $s1_st and defined $s1_end );

		# get timestamps for the subtitle from the 'Refragment SRT' file
		my ($s2_st, $s2_end) = $so->get_start_end( $s2->{'t'} );

		# tolerate bad timestamps in the 'Refragment SRT' file because we
		# will later copy the timestamps from the 'Reference SRT' file
		unless ( defined $s2_st and defined $s2_end )
		{
			$s_start = $i2 unless ( $started );
			$started = 1;
			push @$section_srts2, $srt2->[$i2];
			$i2++;
			next;
		}

		# we have a difference betwen the start or end timestamps
		if ( not &equal( $s1_st, $s2_st ) or not &equal( $s1_end, $s2_end ) )
		{
			# mark current srt as beginning of differing fragmentation section
			$s_start = $i2 unless ( $started );
			$started = 1;

			# compare the end timestamps
			my $cmp = &compare( $s1_end, $s2_end );
			# equal - remember current subtitles for both sections and increase both indices
			if ( $cmp == 0 )
			{
				push @$section_srts2, $srt2->[$i2];
				$i2++;
				push @$section_srts1, $srt1->[$i1];
				$i1++;
				next;
			}
			# $s1_end > $s2_end - remember current subtitle for 'Refragment SRT' section, move index
			elsif ( $cmp > 0 )
			{
				push @$section_srts2, $srt2->[$i2];
				$i2++;
				next;
			}
			# $s1_end < $s2_end - remember current subtitle for 'Reference SRT' section, move index
			elsif ( $cmp < 0 )
			{
				push @$section_srts1, $srt1->[$i1];
				$i1++;
				next;
			}
		}
		# timestamps match
		else
		{
			# if we have started a differing fragmentation section, this marks its end
			if ( $started )
			{
				last;
			}
			# if everything has been equal so far, keep searching further
			else
			{
				$i1++;
				$i2++;
			}
		}
	}
}

sub equal
{
	my ($ts1, $ts2) = @_;

	my $t1 = $so->timestamp_as_num( $ts1 );
	my $t2 = $so->timestamp_as_num( $ts2 );
	return 0 unless ( defined $t1 and defined $t2 );

	return ( abs( $t1 - $t2 ) < $eq_margin ) ? 1 : 0;
}

sub compare
{
	my ($ts1, $ts2) = @_;

	my $t1 = $so->timestamp_as_num( $ts1 );
	my $t2 = $so->timestamp_as_num( $ts2 );
	return 0 unless ( defined $t1 and defined $t2 );

	return $t1 - $t2;
}

sub print_tool_header
{
	print "<body>\n";
	$so->print_tools_menu();
	print "<h1>Refragment SRT</h1>\n";
}

sub print_project_header
{
	print qq{
<h3>Project: $project</h3>
<h4>SRT files in project:</h4>

<b>Reference SRT:&nbsp;</b> $fn1<br>
<b>Refragment SRT:</b> $fn2<br><br>
	};
}

sub print_file_form
{
	&print_tool_header();

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print 'Reference SRT: &nbsp;', $q->filefield( 'file1', '', 75, 200 ), "<br><br>\n";
	print 'Refragment SRT: ', $q->filefield( 'file2', '', 75, 200 ), "<br><br>\n";
	print "The two files you submit will automatically create a project that you can work on later.<br>
		The upload of the file may take some time depending on how big they are. Once the files are<br>
		uploaded, they are saved on the server and viewing their diffs is much quicker. Use the option<br>
		below for a project you have already started (files uploaded)<br><br>\n";
	print $q->submit( 'submit', 'Upload Files and View' ), "<br><br>\n";
	print $q->end_form;

	print "--- OR ---<br><br>\n";

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print 'Existing Project: ', $q->textfield( 'project', '', 75, 200 ), "<br><br>\n";
	print "If you enter a number here for an existing project, the file inputs above will be ignored.<br><br>\n";
	print $q->submit( 'submit', 'View' ), "<br><br>\n";
	print $q->end_form;
	print "</body>\n";
}

sub print_refragment_form
{
	# get the number of subtitles in the 'Reference SRT' fragment section
	my $cnt = scalar @$section_srts1;

	# this happens when there are no more fragmentation differences (or file2 has extra srts at the end)
	unless ( $cnt > 0 ) {
		&print_sync_form();
		return;
	}

	# get the number of subtitles in the 'Refragment SRT' fragment section
	my $s_size = scalar @$section_srts2;

	# get the cumulative subtitle text for the 'Refragment SRT' fragment section
	my $text = ( $s_size > 0 ) ?
		join( ' ', map { $_->{'txt'} } @$section_srts2 ) :
		'[ -- MISSING SUBTITLE -- ]';
	$text = $q->escapeHTML( $text );


	&print_tool_header();
	&print_project_header();

	print qq{
If you scroll down (the green box may be hiding it) you will see a section in the 'Refragment SRT' where the subtitles are fragmented differently from the 'Reference SRT'. The green textarea box contains all the text from the section. The table underneath it contains the fragmentation from the 'Reference SRT' and empty boxes. You can cut (cut instead of copy will make your life easier) text from the green box and paste it into the boxes to refragment the text. Even easier way to do this is to click inside the green box in the position where the line should end, then press the "Enter" key - the line will automatically be cut/pasted in the first available empty box. After you have refragmented the text from the green box, click 'Refragment' - the 'Refragment SRT' file will be modified with your new fragmentation. Also, all subtitles up to this point will be synchronized with the 'Reference SRT' file. You will then see the next section where the two files are fragmented differently.<br><br>

At any time you can also click 'Export Refragmented File' to download the latest version of the 'Refragment SRT' file. However, it is best to export after you have had a chance to also 'Synchronize Timestamps'. That option is available to you only at the end, after you have resolved all fragmentation differences sections between the two SRT files. Synchronization removes tiny timestamp differences (less than $eq_margin milliseconds).<br><br>
	};

	print_refrag_js();

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
<input type="hidden" name="step" value="refragment">
<input type="hidden" name="project" value="$project">
<input type="hidden" name="section_start" value="$s_start">
<input type="hidden" name="section_size" value="$s_size">

<div style="position: fixed; bottom: 0px; left: 0px; z-index: 5; background-color: rgb(180, 250, 180);">
<textarea id="boxtxt" name="dummy" rows="4" cols="80"
	style="background: inherit;">$text</textarea>
</div>

<table border="1" cellpadding="5">
<tr><th>Refragment SRT</th><th>Reference SRT</th><th>Sub #</th></tr>
	};

	# print as many text boxes as the 'Reference SRT' file has for the fragment section
	foreach my $s ( @$section_srts1 )
	{
		my $sub_txt = $s->{'txt'};
		$sub_txt = $q->escapeHTML( $sub_txt );

		print qq{
<tr class="datarow">
	<td>
		<input type="text" name="fragment_$s->{'c'}" value="" size="77" class="sinput">
	</td>
	<td>
		$s->{'t'}<br>
		$sub_txt
	</td>
	<td align="center">$s->{'c'}</td>
</tr>
		};
	}

	print "</table>\n<br>\n";

	print $q->submit( 'submit', 'Refragment' ), "<br><br>\n";
	print $q->end_form;

	# a separate form/button for export of the final version
	print "<br><hr><br>";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{<input type="hidden" name="step" value="export">\n};
	print qq{<input type="hidden" name="project" value="$project">\n};
	print $q->submit( 'submit', 'Export Refragmented File' ), "<br><br>\n";
	print $q->end_form;
	print qq{<br><div style="height:400px;">&nbsp;</div><br>};
	print "</body>\n";
}

sub print_sync_form
{
	&print_tool_header();
	&print_project_header();

	print qq{
The 'Reference SRT' file and the 'Refragment SRT' do not have any more fragmentation differences.<br>
There may be still some minor timestamp differences. You can click 'Synchronize Timestamps' below to<br>
synchronize the timestamps from 'Reference SRT' file into the 'Refragment SRT' file. And then, you<br>
can click 'Export' to download the final version of the 'Refragment SRT' file to your computer.<br><br>
	};

	# a separate form/button for synchronizing timestamps
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
<input type="hidden" name="step" value="sync">
<input type="hidden" name="project" value="$project">
	};
	print $q->submit( 'submit', 'Synchronize Timestamps' ), "<br><br>\n";
	print $q->end_form;

	# a separate form/button for export of the final version
	print "<br><hr><br>";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{<input type="hidden" name="step" value="export">\n};
	print qq{<input type="hidden" name="project" value="$project">\n};
	print $q->submit( 'submit', 'Export Refragmented File' ), "<br><br>\n";
	print $q->end_form;
	print "</body>\n"
}

# just get the contents of file2 (Refragment SRT) and print it
sub export_refragmented_file
{
	my $file_txt = '';

	&read_file2( \$file_txt );

	my $filename = $fn2;
	if ( $filename =~ /\.srt$/i ) {
		$filename =~ s/\.srt/.exported.srt/i;
	} else {
		$filename .= '.exported.srt';
	}

	print $q->header(
		-type       => 'text/plain',
		-charset    => $encoding,
		-attachment => $filename
	);
	print $file_txt;
}

sub print_refrag_js {

	print << 'EOF';

<script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.7.2/jquery.min.js"></script>
<script type="text/javascript" src="/js/frag.js?v=2"></script>

<script type="text/javascript">

$(document).ready( function() {
	$('#boxtxt').keypress( box_cut_paste );
});

</script>

EOF

}

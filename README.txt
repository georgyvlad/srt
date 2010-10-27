The SRT Editor is a set of web-based tools for handling SRT (movie subtitles) files.

The "diff" utility lets users look at slight differences between two versions of the same SRT file (number of subtitles have to match). Then, it lets users merge the two versions by picking the subtitle from either file or editing in a custom version for a subtitle.

The "tmshift" tool lets users combine multi-part SRTs into one big SRT file, while allowing for time-shifting the timestamps of the consequent files (because each part starts its timestamps from zero).

The "frag" tool is intended for analyzing and adjusting the subtitles' fragmentation inside two SRT files that are very similar.  The files are usually two versions of the same video (timestamps are identical) with very small differences. The first SRT file serves as the base for comparison, and the second will be compared and adjusted.

The source code is in the Perl programming language, so the utilities can be installed on any webserver that supports Perl CGI. To install the utilities you just have to copy the files somewhere under the CGI directory (e. g. 'cgi-bin'):

cp SRT.pm /cgi-bin/srt/
cp diff.pl /cgi-bin/srt/
cp tmshift.pl /cgi-bin/srt/
cp frag.pl /cgi-bin/srt/

No further configuration is needed. The utilities use the webserver's local file system to save their data. So, the first time data needs to be saved the tools will create their data directories in the same directory (in this case '/cgi-bin/srt'). The tools are smart enough to automatically erase older (2 month old at the moment) datafiles once in a while.

You should be able to access the tools now like this:

http://yourserver.com/cgi-bin/srt/diff.pl
http://yourserver.com/cgi-bin/srt/tmshift.pl
http://yourserver.com/cgi-bin/srt/frag.pl

Original author: Georgy Vladimirov

Licence: The work is volunteered contribution to the Zeitgeist Movement (http://www.thezeitgeistmovement.com)
It is Open Source and licenced as the Perl language itself (under the Artistic Licence and the
GNU General Public Licence).

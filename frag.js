function box_cut_paste( e ) {
	// we only care when Enter key is pressed
	if ( e.which != 13 ) { return; }

	// prevent Enter key from inserting newline in the textbox
	e.preventDefault();

	var b = $('#boxtxt').get(0);
	var box = b.value;
	var pos = 0;

	// get cursor position at moment of keypress (browswer specific)
	if ( 'selectionStart' in b ) {
		pos = b.selectionStart;
	} else if ( 'selection' in document ) {
		// old IE crap here
		b.focus();
		var sel = document.selection.createRange();
		var slen = document.selection.createRange().text.length;
		sel.moveStart( 'character', -b.value.length );
		pos = sel.text.length - slen;
	}

	// split the box text into line and rest based on pos
	var ln = box.substr(0, pos);
	ln = ln.replace( /^\s+|\s+$/gm, '' );

	var rest = box.substr(pos);
	rest = rest.replace( /^\s+|\s+$/gm, '' );

	// find the first empty input and stick line there
	$('.datarow :text.sinput').each( function (){
		var s = $(this);
		var found = 0;

		if ( s.val() == '' ) {
			s.val( ln );
			found = 1;
		}

		if ( found ) { return false }
	});

	// update the box
	b.value = rest;

	// position cursor in front
	if ( b.createTextRange ) {
		var part = b.createTextRange();
		part.moveat("character", 0);
		part.moveEnd("character", 0);
		part.select();
	} else if ( b.setSelectionRange ){
		b.setSelectionRange(0, 0);
	}
}

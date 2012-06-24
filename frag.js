function box_cut_paste() {
	var box = $('#boxtxt').val();
	var upd = 0;

	// replace possible leading newline chars
	if ( box.match( /^\s+/ ) ) {
		box = box.replace( /^\s+/, '' );
		upd = 1;
	}

	// grab the first line and remove it
	var ln = box.match( /^([^\n\r]+)[\n\r]+/ );
	if ( !( ln === null )  ) {
		ln = ln[0];
		box = box.replace( /^.+[\n\r]+\s*/, '' );
		upd = 1;
	}

	// check each table row
	$('.datarow :text.sinput').each( function (){
		var s = $(this);
		var found = 0;

		if ( s.val() == '' ) {
			s.val( ln );
			found = 1;
		}

		if ( found ) { return false }
	});

	// need to update the box
	if ( upd == 1 ) {
		$('#boxtxt').val( box );

		// position cursor in front
		var b = $('#boxtxt').get(0);
		if ( b.createTextRange ) {
			var part = b.createTextRange();
			part.moveat("character", 0);
			part.moveEnd("character", 0);
			part.select();
		} else if ( b.setSelectionRange ){
			b.setSelectionRange(0, 0);
		}
	}
}

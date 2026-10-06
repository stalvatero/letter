/* Rows in the folder, message and thread lists are replaced whenever those
 * lists are rebuilt. A row that is still alive once it is out of its list is
 * memory that never comes back. */

class RowWatch : Object {
    public bool finalized;

    public void on_finalized (Object row) {
        this.finalized = true;
    }
}

void check_freed (string what, owned Gtk.Widget row, Gtk.Widget list) {
    var watch = new RowWatch ();
    row.weak_ref (watch.on_finalized);
    if (list is Gtk.ListBox) {
        ((Gtk.ListBox) list).append (row);
        ((Gtk.ListBox) list).remove (row);
    } else {
        ((Gtk.Box) list).append (row);
        ((Gtk.Box) list).remove (row);
    }
    row = null;
    if (!watch.finalized)
        error ("a %s removed from its list is never freed", what);
}

int main (string[] args) {
    if (!Gtk.init_check ()) {
        print ("rows: no display, row lifetime not checked\n");
        return 0;
    }

    var list = new Gtk.ListBox ();
    var folder = new Mail.Folder () {
        name = "Inbox",
        full_name = "INBOX",
        has_children = true,
    };
    check_freed ("folder row", new Mail.FolderRow (folder), list);

    /* Message rows are list-view items, not list box rows. */
    check_freed ("message row", new Mail.MessageRow (), new Gtk.Box (Gtk.Orientation.VERTICAL, 0));

    check_freed ("thread row", new Mail.ThreadRow (new Mail.Message () { uid = "1" }), list);
    return 0;
}

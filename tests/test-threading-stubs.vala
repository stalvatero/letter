namespace Mail.Utils {
    public static string format_message_date (int64 unix_time) {
        return unix_time.to_string ();
    }

    public static Pango.AttrList? search_highlight_attrs (string text, GenericArray<string>? tokens) {
        return null;
    }

    public static string? sanitize_message_preview (string? raw) {
        if (raw == null || raw.length == 0)
            return null;
        return raw;
    }

    public static Gtk.Image account_provenance_image (Account account, int pixel_size = 16) {
        var image = new Gtk.Image.from_icon_name (account.provenance_icon_name);
        image.pixel_size = pixel_size;
        return image;
    }
}

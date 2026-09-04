namespace Mail.Utils {
    public static string format_message_date (int64 unix_time) {
        return unix_time.to_string ();
    }

    public static Pango.AttrList? search_highlight_attrs (string text, GenericArray<string>? tokens) {
        return null;
    }
}

public enum Mail.SearchFilterKind {
    FROM,
    TO,
    TEXT
}

public class Mail.SearchClause : Object {
    public SearchFilterKind kind { get; set; }
    public string folded { get; set; default = ""; }
    public string display { get; set; default = ""; }
}

public class Mail.SearchQuery : Object {
    public GenericArray<SearchClause> clauses = new GenericArray<SearchClause> ();
    /* When true, TEXT clauses match if any token hits (FROM/TO still AND). */
    public bool match_any { get; set; default = false; }

    public bool is_empty {
        get {
            return this.clauses.length == 0;
        }
    }

    public uint text_clause_count {
        get {
            uint n = 0;
            for (uint i = 0; i < this.clauses.length; i++) {
                if (this.clauses[i].kind == SearchFilterKind.TEXT
                    && this.clauses[i].folded.length > 0)
                    n++;
            }
            return n;
        }
    }

    public string key {
        owned get {
            if (this.clauses.length == 0)
                return "";

            var builder = new StringBuilder ();
            for (uint i = 0; i < this.clauses.length; i++) {
                var clause = this.clauses[i];
                if (builder.len > 0)
                    builder.append_c (' ');
                builder.append (kind_key (clause.kind));
                builder.append_c (':');
                builder.append (clause.folded);
            }
            if (this.match_any)
                builder.append ("|any");
            return builder.str;
        }
    }

    public void add (SearchFilterKind kind, string raw) {
        var display = raw.strip ();
        var folded = display.casefold ();
        if (folded.length == 0)
            return;

        this.clauses.add (new SearchClause () {
            kind = kind,
            folded = folded,
            display = display,
        });
    }

    public void add_clause (SearchClause clause) {
        if (clause.folded.length == 0)
            return;
        this.clauses.add (clause);
    }

    public SearchQuery merge_text (string? raw) {
        var extra = parse (raw);
        var merged = copy ();
        for (uint i = 0; i < extra.clauses.length; i++)
            merged.add_clause (extra.clauses[i]);
        return merged;
    }

    public SearchQuery copy () {
        var clone = new SearchQuery ();
        clone.match_any = this.match_any;
        for (uint i = 0; i < this.clauses.length; i++) {
            var clause = this.clauses[i];
            clone.clauses.add (new SearchClause () {
                kind = clause.kind,
                folded = clause.folded,
                display = clause.display,
            });
        }
        return clone;
    }

    public GenericArray<string> highlight_tokens () {
        var tokens = new GenericArray<string> ();
        for (uint i = 0; i < this.clauses.length; i++)
            append_folded_words (this.clauses[i].folded, tokens);
        return tokens;
    }

    public GenericArray<string> text_tokens () {
        var tokens = new GenericArray<string> ();
        for (uint i = 0; i < this.clauses.length; i++) {
            if (this.clauses[i].kind == SearchFilterKind.TEXT)
                append_folded_words (this.clauses[i].folded, tokens);
        }
        return tokens;
    }

    /* Multi-word TEXT chips keep one pill in the UI; matching ANDs each word. */
    public static GenericArray<string> folded_words (string folded) {
        var words = new GenericArray<string> ();
        append_folded_words (folded, words);
        return words;
    }

    private static void append_folded_words (string folded, GenericArray<string> words) {
        if (folded.length == 0)
            return;

        int i = 0;
        unichar c;
        while (i < folded.length) {
            while (i < folded.length) {
                var next = i;
                folded.get_next_char (ref next, out c);
                if (!c.isspace ())
                    break;
                i = next;
            }
            if (i >= folded.length)
                break;

            var start = i;
            while (i < folded.length) {
                var next = i;
                folded.get_next_char (ref next, out c);
                if (c.isspace ())
                    break;
                i = next;
            }
            var word = folded.substring (start, i - start);
            if (word.length > 0)
                words.add (word);
        }
    }

    public static bool folded_matches_haystack (string haystack, string folded, bool match_any) {
        var words = folded_words (folded);
        if (words.length == 0)
            return false;
        if (match_any) {
            for (uint i = 0; i < words.length; i++) {
                if (haystack.contains (words[i]))
                    return true;
            }
            return false;
        }
        for (uint i = 0; i < words.length; i++) {
            if (!haystack.contains (words[i]))
                return false;
        }
        return true;
    }

    public static string chip_label (SearchClause clause) {
        switch (clause.kind) {
            case SearchFilterKind.FROM:
                return _("From: %s").printf (clause.display);
            case SearchFilterKind.TO:
                return _("To: %s").printf (clause.display);
            default:
                /* Compact chip: symbol instead of the long “Contains:” prefix. */
                return "∋ %s".printf (clause.display);
        }
    }

    public static string kind_suggestion (SearchFilterKind kind, string needle) {
        switch (kind) {
            case SearchFilterKind.FROM:
                return _("From: %s").printf (needle);
            case SearchFilterKind.TO:
                return _("To: %s").printf (needle);
            default:
                return _("Contains: %s").printf (needle);
        }
    }

    public static bool incomplete_prefix (string? raw, out SearchFilterKind kind) {
        kind = SearchFilterKind.TEXT;
        if (raw == null)
            return false;

        var token = last_token (raw).casefold ();
        if (token.length == 0 || !token.has_suffix (":"))
            return false;

        SearchFilterKind matched;
        int after;
        if (!match_prefix (token, 0, out matched, out after))
            return false;
        if (after != token.length)
            return false;
        kind = matched;
        return true;
    }

    /* Localized operator tip for the search field (English operators always work too). */
    public static string filter_hint () {
        return _("Search all folders. Enter searches. Pick %s or %s to pin a chip.").printf (
            C_("Search filter", "from:"),
            C_("Search filter", "to:")
        );
    }

    /* True when the draft uses from:/to:/contains: (localized forms included). */
    public static bool has_filter_operators (string? raw) {
        if (raw == null)
            return false;

        int i = 0;
        unichar c;
        while (i < raw.length) {
            var next = i;
            raw.get_next_char (ref next, out c);
            if (c.isspace ()) {
                i = next;
                continue;
            }

            SearchFilterKind kind;
            int after;
            if (match_prefix (raw, i, out kind, out after))
                return true;

            i = next;
            while (i < raw.length) {
                next = i;
                raw.get_next_char (ref next, out c);
                if (c.isspace ())
                    break;
                i = next;
            }
        }
        return false;
    }

    public static SearchQuery parse (string? raw) {
        var query = new SearchQuery ();
        if (raw == null)
            return query;

        int i = 0;
        unichar c;
        while (i < raw.length) {
            var next = i;
            raw.get_next_char (ref next, out c);
            if (c.isspace ()) {
                i = next;
                continue;
            }

            SearchFilterKind kind;
            int after;
            if (match_prefix (raw, i, out kind, out after)) {
                i = after;
                while (i < raw.length) {
                    next = i;
                    raw.get_next_char (ref next, out c);
                    if (!c.isspace ())
                        break;
                    i = next;
                }
                string value;
                i = read_value (raw, i, out value);
                if (kind != SearchFilterKind.TEXT)
                    query.add (kind, value);
                else if (value.length > 0)
                    query.add (SearchFilterKind.TEXT, value);
                continue;
            }

            string value;
            i = read_value (raw, i, out value);
            if (value.length > 0)
                query.add (SearchFilterKind.TEXT, value);
        }
        return query;
    }

    public static bool matches_message (Message message, SearchQuery query) {
        if (query.is_empty)
            return true;

        var from_hay = message.from_blob != null && message.from_blob.length > 0
            ? message.from_blob
            : haystack (message.from);
        var to_hay = message.to_blob != null && message.to_blob.length > 0
            ? message.to_blob
            : to_haystack (message);
        var text_hay = message.search_blob ?? "";
        if (text_hay.length == 0) {
            var blob = new StringBuilder ();
            Utils.append_search_part (blob, message.subject);
            Utils.append_search_part (blob, message.from);
            Utils.append_search_part (blob, message.to);
            Utils.append_search_part (blob, message.cc);
            Utils.append_search_part (blob, message.list_address);
            Utils.append_search_part (blob, message.preview);
            text_hay = blob.str;
        }

        var has_text = false;
        var text_ok = false;
        for (uint i = 0; i < query.clauses.length; i++) {
            var clause = query.clauses[i];
            switch (clause.kind) {
                case SearchFilterKind.FROM:
                    if (!from_hay.contains (clause.folded))
                        return false;
                    break;
                case SearchFilterKind.TO:
                    if (!to_hay.contains (clause.folded))
                        return false;
                    break;
                case SearchFilterKind.TEXT:
                    has_text = true;
                    var hit = folded_matches_haystack (text_hay, clause.folded, false);
                    if (query.match_any) {
                        if (hit)
                            text_ok = true;
                    } else if (!hit) {
                        return false;
                    } else {
                        text_ok = true;
                    }
                    break;
            }
        }
        return !has_text || text_ok;
    }

    /* FROM/TO only — TEXT is already satisfied by a body-index hit. */
    public static bool matches_header_filters (Message message, SearchQuery query) {
        if (query.is_empty)
            return true;

        var from_hay = message.from_blob != null && message.from_blob.length > 0
            ? message.from_blob
            : haystack (message.from);
        var to_hay = message.to_blob != null && message.to_blob.length > 0
            ? message.to_blob
            : to_haystack (message);

        for (uint i = 0; i < query.clauses.length; i++) {
            var clause = query.clauses[i];
            switch (clause.kind) {
                case SearchFilterKind.FROM:
                    if (!from_hay.contains (clause.folded))
                        return false;
                    break;
                case SearchFilterKind.TO:
                    if (!to_hay.contains (clause.folded))
                        return false;
                    break;
                default:
                    break;
            }
        }
        return true;
    }

    private static string haystack (string? value) {
        return value != null ? value.casefold () : "";
    }

    private static string to_haystack (Message message) {
        var blob = new StringBuilder ();
        Utils.append_search_part (blob, message.to);
        Utils.append_search_part (blob, message.cc);
        Utils.append_search_part (blob, message.list_address);
        return blob.str;
    }

    private static string last_token (string text) {
        int i = text.length;
        unichar c;
        while (i > 0) {
            var prev = i;
            text.get_prev_char (ref prev, out c);
            if (!c.isspace ())
                break;
            i = prev;
        }
        var end = i;
        while (i > 0) {
            var prev = i;
            text.get_prev_char (ref prev, out c);
            if (c.isspace ())
                break;
            i = prev;
        }
        if (end <= i)
            return "";
        return text.substring (i, end - i);
    }

    private static string kind_key (SearchFilterKind kind) {
        switch (kind) {
            case SearchFilterKind.FROM:
                return "from";
            case SearchFilterKind.TO:
                return "to";
            default:
                return "contains";
        }
    }

    private static bool match_prefix (string text, int start, out SearchFilterKind kind, out int after) {
        kind = SearchFilterKind.TEXT;
        after = start;
        var rest = text.substring (start).casefold ();

        /* English operators always work. Localized aliases come from gettext
         * (msgctxt "Search filter"). Longer tokens are tried first. */
        if (try_prefix (rest, start, "contains:", SearchFilterKind.TEXT, out kind, out after)
            || try_prefix (rest, start, norm_filter_prefix (C_("Search filter", "contains:")), SearchFilterKind.TEXT, out kind, out after)
            || try_prefix (rest, start, "from:", SearchFilterKind.FROM, out kind, out after)
            || try_prefix (rest, start, norm_filter_prefix (C_("Search filter", "from:")), SearchFilterKind.FROM, out kind, out after)
            || try_prefix (rest, start, "to:", SearchFilterKind.TO, out kind, out after)
            || try_prefix (rest, start, norm_filter_prefix (C_("Search filter", "to:")), SearchFilterKind.TO, out kind, out after)
            || try_prefix (rest, start, "cc:", SearchFilterKind.TO, out kind, out after))
            return true;
        return false;
    }

    private static string norm_filter_prefix (string raw) {
        var local = raw.casefold ().strip ();
        if (local.length == 0)
            return "";
        if (!local.has_suffix (":"))
            local += ":";
        return local;
    }

    private static bool try_prefix (
        string rest,
        int start,
        string prefix,
        SearchFilterKind matched,
        out SearchFilterKind kind,
        out int after
    ) {
        kind = SearchFilterKind.TEXT;
        after = start;
        if (prefix.length == 0 || !rest.has_prefix (prefix))
            return false;
        kind = matched;
        after = start + prefix.length;
        return true;
    }

    private static int read_value (string text, int start, out string value) {
        value = "";
        if (start >= text.length)
            return start;

        unichar c;
        var next = start;
        text.get_next_char (ref next, out c);
        if (c == '"') {
            var inner = new StringBuilder ();
            var i = next;
            while (i < text.length) {
                next = i;
                text.get_next_char (ref next, out c);
                if (c == '"') {
                    value = inner.str.strip ();
                    return next;
                }
                inner.append_unichar (c);
                i = next;
            }
            value = inner.str.strip ();
            return text.length;
        }

        var word = new StringBuilder ();
        var i = start;
        while (i < text.length) {
            next = i;
            text.get_next_char (ref next, out c);
            if (c.isspace ())
                break;
            word.append_unichar (c);
            i = next;
        }
        value = word.str.strip ();
        return i;
    }
}

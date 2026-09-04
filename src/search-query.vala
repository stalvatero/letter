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

    public bool is_empty {
        get {
            return this.clauses.length == 0;
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
            tokens.add (this.clauses[i].folded);
        return tokens;
    }

    public GenericArray<string> text_tokens () {
        var tokens = new GenericArray<string> ();
        for (uint i = 0; i < this.clauses.length; i++) {
            if (this.clauses[i].kind == SearchFilterKind.TEXT)
                tokens.add (this.clauses[i].folded);
        }
        return tokens;
    }

    public static string chip_label (SearchClause clause) {
        switch (clause.kind) {
            case SearchFilterKind.FROM:
                return _("From: %s").printf (clause.display);
            case SearchFilterKind.TO:
                return _("To: %s").printf (clause.display);
            default:
                return _("Contains: %s").printf (clause.display);
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
        if (token == "contains:" || token == "contiene:") {
            kind = SearchFilterKind.TEXT;
            return true;
        }
        if (token == "from:" || token == "da:") {
            kind = SearchFilterKind.FROM;
            return true;
        }
        if (token == "to:" || token == "cc:" || token == "a:") {
            kind = SearchFilterKind.TO;
            return true;
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
                    if (!text_hay.contains (clause.folded))
                        return false;
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
        if (take_prefix (rest, start, "contains:", SearchFilterKind.TEXT, out kind, out after)
            || take_prefix (rest, start, "contiene:", SearchFilterKind.TEXT, out kind, out after)
            || take_prefix (rest, start, "from:", SearchFilterKind.FROM, out kind, out after)
            || take_prefix (rest, start, "da:", SearchFilterKind.FROM, out kind, out after)
            || take_prefix (rest, start, "to:", SearchFilterKind.TO, out kind, out after)
            || take_prefix (rest, start, "cc:", SearchFilterKind.TO, out kind, out after)
            || take_prefix (rest, start, "a:", SearchFilterKind.TO, out kind, out after))
            return true;
        return false;
    }

    private static bool take_prefix (
        string rest,
        int start,
        string prefix,
        SearchFilterKind matched,
        out SearchFilterKind kind,
        out int after
    ) {
        kind = SearchFilterKind.TEXT;
        after = start;
        if (!rest.has_prefix (prefix))
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

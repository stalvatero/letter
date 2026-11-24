/* Profile pictures for the accounts rail (Google + Microsoft 365).
 * GOA accounts use the Online Accounts token; Letter Identity uses libsecret. */
public class Mail.AccountAvatars : Object {
    private const string GOOGLE_USERINFO_URL = "https://www.googleapis.com/oauth2/v2/userinfo";
    private const string MICROSOFT_PHOTO_URL = "https://graph.microsoft.com/v1.0/me/photos/48x48/$value";
    private const int PICTURE_SIZE = 64;

    private Soup.Session session = new Soup.Session ();
    private HashTable<string, Gdk.Texture> pictures = new HashTable<string, Gdk.Texture> (str_hash, str_equal);

    /** Prefer Letter Identity OAuth, else GOA when present. */
    public async Gdk.Texture? load_for_account (Account account, Goa.Client? goa) {
        if (account.is_letter_identity)
            return yield load_identity (account);
        if (goa != null && account.has_goa)
            return yield load_goa (goa, account);
        return null;
    }

    /* The account's picture, or null when it has none or it cannot be fetched. */
    public async Gdk.Texture? load_goa (Goa.Client goa, Account account) {
        var id = account.goa_id;
        if (id == null)
            return null;
        var cached = this.pictures.get (id);
        if (cached != null)
            return cached;

        var oauth = goa.lookup_by_id (id)?.get_oauth2_based ();
        if (oauth == null)
            return null;
        try {
            string token;
            int expires_in;
            yield oauth.call_get_access_token (null, out token, out expires_in);
            var picture = yield fetch_picture (account.kind, token);
            if (picture != null)
                this.pictures.set (id, picture);
            return picture;
        } catch (Error e) {
            debug ("No account picture for %s: %s", id, e.message);
            return null;
        }
    }

    private async Gdk.Texture? load_identity (Account account) {
        var id = account.source_uid ?? account.uid;
        if (id == null || id.length == 0)
            return null;
        var cache_key = "identity:" + id;
        var cached = this.pictures.get (cache_key);
        if (cached != null)
            return cached;

        IdentityAccount? row = null;
        try {
            var catalog = IdentityCatalog.load ();
            for (uint i = 0; i < catalog.accounts.length; i++) {
                if (catalog.accounts[i].id == id) {
                    row = catalog.accounts[i];
                    break;
                }
            }
        } catch (Error e) {
            debug ("Identity catalog for avatar: %s", e.message);
            return null;
        }
        if (row == null || !row.uses_oauth2 ())
            return null;

        string? token = null;
        Error? token_error = null;
        var acc = row;
        SourceFunc resume = load_identity.callback;
        new Thread<void*> ("letter-avatar-token", () => {
            try {
                token = IdentityOAuth.ensure_access_token_sync (acc);
            } catch (Error e) {
                token_error = e;
            }
            Idle.add (() => {
                resume ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (token_error != null || token == null || token.length == 0) {
            debug ("No Identity token for avatar %s: %s",
                id, token_error != null ? token_error.message : "empty");
            return null;
        }

        try {
            var picture = yield fetch_picture (account.kind, token);
            if (picture != null)
                this.pictures.set (cache_key, picture);
            return picture;
        } catch (Error e) {
            debug ("No Identity picture for %s: %s", id, e.message);
            return null;
        }
    }

    private async Gdk.Texture? fetch_picture (AccountKind kind, string token) throws Error {
        switch (kind) {
            case AccountKind.GOOGLE:
                return yield load_google (token);
            case AccountKind.MICROSOFT:
                return yield load_microsoft (token);
            default:
                return null;
        }
    }

    /* The picture link from a Google userinfo reply, asking for size pixels. */
    public static string? picture_url (Bytes userinfo, int size) {
        if (userinfo.get_size () == 0)
            return null;
        var parser = new Json.Parser ();
        try {
            unowned uint8[] data = userinfo.get_data ();
            parser.load_from_data ((string) data, data.length);
        } catch (Error e) {
            return null;
        }
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            return null;

        string? picture = root.get_object ().get_string_member_with_default ("picture", "");
        if (picture == null || !picture.has_prefix ("https://"))
            return null;
        var link = picture.split_set ("?#")[0];
        var options = link.last_index_of_char ('=');
        if (options > link.last_index_of_char ('/'))
            link = link.substring (0, options);
        return "%s=s%d-c".printf (link, size);
    }

    private async Gdk.Texture? load_google (string token) throws Error {
        var url = picture_url (yield fetch (GOOGLE_USERINFO_URL, token), PICTURE_SIZE);
        if (url == null)
            return null;
        return Gdk.Texture.from_bytes (yield fetch (url, null));
    }

    private async Gdk.Texture? load_microsoft (string token) throws Error {
        try {
            return Gdk.Texture.from_bytes (yield fetch (MICROSOFT_PHOTO_URL, token));
        } catch (Error e) {
            /* 404 when the account has no photo — initials stay. */
            debug ("No Microsoft photo: %s", e.message);
            return null;
        }
    }

    private async Bytes fetch (string url, string? token) throws Error {
        var message = new Soup.Message ("GET", url);
        if (token != null)
            message.request_headers.append ("Authorization", "Bearer " + token);
        var body = yield this.session.send_and_read_async (message, Priority.DEFAULT, null);
        if (message.status_code != Soup.Status.OK)
            throw new IOError.FAILED ("HTTP %u", message.status_code);
        return body;
    }
}

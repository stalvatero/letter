/**
 * libsecret / Flatpak secret-portal storage for Identity passwords and OAuth.
 * Never log the secret value.
 */
public class Mail.IdentitySecrets : Object {
    private static Secret.Schema schema () {
        /* Varargs: name, type pairs, then null. */
        return new Secret.Schema (
            "io.github.stalvatero.Letter.Identity",
            Secret.SchemaFlags.NONE,
            "account_id",
            Secret.SchemaAttributeType.STRING,
            null
        );
    }

    private static Secret.Schema oauth_schema () {
        return new Secret.Schema (
            "io.github.stalvatero.Letter.Identity.OAuth",
            Secret.SchemaFlags.NONE,
            "account_id",
            Secret.SchemaAttributeType.STRING,
            null
        );
    }

    public static void store_password (string account_id, string label, string password) throws Error {
        Secret.password_store_sync (
            schema (),
            Secret.COLLECTION_DEFAULT,
            label,
            password,
            null,
            "account_id", account_id,
            null
        );
    }

    public static string? lookup_password (string account_id) throws Error {
        return Secret.password_lookup_sync (
            schema (),
            null,
            "account_id", account_id,
            null
        );
    }

    public static void clear_password (string account_id) throws Error {
        Secret.password_clear_sync (
            schema (),
            null,
            "account_id", account_id,
            null
        );
    }

    public static void store_oauth_tokens (
        string account_id,
        string label,
        IdentityOAuthTokens tokens
    ) throws Error {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("access_token");
        builder.add_string_value (tokens.access_token);
        if (tokens.refresh_token != null) {
            builder.set_member_name ("refresh_token");
            builder.add_string_value (tokens.refresh_token);
        }
        builder.set_member_name ("expires_at");
        builder.add_int_value (tokens.expires_at);
        if (tokens.token_type != null) {
            builder.set_member_name ("token_type");
            builder.add_string_value (tokens.token_type);
        }
        builder.end_object ();
        var gen = new Json.Generator ();
        gen.set_root (builder.get_root ());
        var json = gen.to_data (null);
        Secret.password_store_sync (
            oauth_schema (),
            Secret.COLLECTION_DEFAULT,
            label,
            json,
            null,
            "account_id", account_id,
            null
        );
    }

    public static IdentityOAuthTokens? lookup_oauth_tokens (string account_id) throws Error {
        var json = Secret.password_lookup_sync (
            oauth_schema (),
            null,
            "account_id", account_id,
            null
        );
        if (json == null || json.length == 0)
            return null;
        var parser = new Json.Parser ();
        /* Pass length so a secret without a trailing NUL cannot walk the heap. */
        parser.load_from_data (json, json.length);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            return null;
        var obj = root.get_object ();
        if (!obj.has_member ("access_token"))
            return null;
        return new IdentityOAuthTokens () {
            access_token = obj.get_string_member ("access_token"),
            refresh_token = obj.has_member ("refresh_token")
                ? obj.get_string_member ("refresh_token") : null,
            expires_at = obj.has_member ("expires_at")
                ? (int64) obj.get_int_member ("expires_at") : 0,
            token_type = obj.has_member ("token_type")
                ? obj.get_string_member ("token_type") : null,
        };
    }

    public static void clear_oauth_tokens (string account_id) throws Error {
        Secret.password_clear_sync (
            oauth_schema (),
            null,
            "account_id", account_id,
            null
        );
    }
}

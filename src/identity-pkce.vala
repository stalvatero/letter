/** PKCE helpers (S256) for public OAuth clients. */
namespace Mail.IdentityPkce {
    public string create_verifier () {
        var bytes = new uint8[32];
        for (int i = 0; i < bytes.length; i++)
            bytes[i] = (uint8) Random.int_range (0, 256);
        return base64_url (bytes);
    }

    public string challenge_s256 (string verifier) {
        var checksum = new Checksum (ChecksumType.SHA256);
        checksum.update (verifier.data, verifier.length);
        size_t len = 32;
        var digest = new uint8[len];
        checksum.get_digest (digest, ref len);
        return base64_url (digest);
    }

    public string create_state () {
        var bytes = new uint8[16];
        for (int i = 0; i < bytes.length; i++)
            bytes[i] = (uint8) Random.int_range (0, 256);
        return base64_url (bytes);
    }

    private string base64_url (uint8[] data) {
        var b64 = Base64.encode (data);
        var sb = new StringBuilder ();
        for (int i = 0; i < b64.length; i++) {
            var c = b64[i];
            if (c == '+')
                sb.append_c ('-');
            else if (c == '/')
                sb.append_c ('_');
            else if (c == '=')
                continue;
            else
                sb.append_c (c);
        }
        return sb.str;
    }
}

// Rocket HTTP NIF — wraps picohttpparser for BEAM integration.
//
// parse_request/1: binary → {:ok, {method, path, query, headers, body_offset, minor_ver}}
//                          | :incomplete | :error
//
// parse_query_string/1: binary → [{key, value}] with percent-decoding

#include <erl_nif.h>
#include <string.h>
#include "picohttpparser.h"

#define MAX_HEADERS 100

// --- Atoms (initialized once at load) ---

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_incomplete;

// Pre-built method atoms
static ERL_NIF_TERM atom_get;
static ERL_NIF_TERM atom_post;
static ERL_NIF_TERM atom_put;
static ERL_NIF_TERM atom_delete;
static ERL_NIF_TERM atom_head;
static ERL_NIF_TERM atom_options;
static ERL_NIF_TERM atom_patch;

static int load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_incomplete = enif_make_atom(env, "incomplete");
    atom_get = enif_make_atom(env, "get");
    atom_post = enif_make_atom(env, "post");
    atom_put = enif_make_atom(env, "put");
    atom_delete = enif_make_atom(env, "delete");
    atom_head = enif_make_atom(env, "head");
    atom_options = enif_make_atom(env, "options");
    atom_patch = enif_make_atom(env, "patch");
    return 0;
}

// --- Helpers ---

static ERL_NIF_TERM make_binary(ErlNifEnv* env, const char* data, size_t len) {
    ERL_NIF_TERM bin;
    unsigned char* buf = enif_make_new_binary(env, len, &bin);
    if (len > 0) memcpy(buf, data, len);
    return bin;
}

static ERL_NIF_TERM method_to_atom(ErlNifEnv* env, const char* method, size_t len) {
    if (len == 3 && memcmp(method, "GET", 3) == 0) return atom_get;
    if (len == 4 && memcmp(method, "POST", 4) == 0) return atom_post;
    if (len == 3 && memcmp(method, "PUT", 3) == 0) return atom_put;
    if (len == 6 && memcmp(method, "DELETE", 6) == 0) return atom_delete;
    if (len == 4 && memcmp(method, "HEAD", 4) == 0) return atom_head;
    if (len == 7 && memcmp(method, "OPTIONS", 7) == 0) return atom_options;
    if (len == 5 && memcmp(method, "PATCH", 5) == 0) return atom_patch;

    // Unknown method — return as lowercase atom
    char lower[32];
    if (len >= sizeof(lower)) len = sizeof(lower) - 1;
    for (size_t i = 0; i < len; i++)
        lower[i] = (method[i] >= 'A' && method[i] <= 'Z') ? method[i] + 32 : method[i];
    lower[len] = '\0';
    return enif_make_atom(env, lower);
}

// --- parse_request/1 ---
//
// Returns: {:ok, {method_atom, path_bin, query_bin, headers_list, body_offset, minor_version}}
//        | :incomplete
//        | :error

static ERL_NIF_TERM nif_parse_request(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary input;
    if (!enif_inspect_binary(env, argv[0], &input)) {
        return enif_make_badarg(env);
    }

    const char* method;
    size_t method_len;
    const char* path;
    size_t path_len;
    int minor_version;
    struct phr_header headers[MAX_HEADERS];
    size_t num_headers = MAX_HEADERS;

    int ret = phr_parse_request(
        (const char*)input.data, input.size,
        &method, &method_len,
        &path, &path_len,
        &minor_version,
        headers, &num_headers,
        0  // last_len = 0 (not doing incremental parse)
    );

    if (ret == -2) {
        return atom_incomplete;
    }
    if (ret == -1) {
        return atom_error;
    }

    // ret is the total bytes consumed (offset where body starts)
    int body_offset = ret;

    // Split path into path and query string at '?'
    const char* query_start = NULL;
    size_t path_only_len = path_len;
    size_t query_len = 0;

    const char* qmark = memchr(path, '?', path_len);
    if (qmark != NULL) {
        path_only_len = qmark - path;
        query_start = qmark + 1;
        query_len = path_len - path_only_len - 1;
    }

    // Build method atom
    ERL_NIF_TERM method_term = method_to_atom(env, method, method_len);

    // Build path binary
    ERL_NIF_TERM path_term = make_binary(env, path, path_only_len);

    // Build query string binary
    ERL_NIF_TERM query_term = (query_start != NULL)
        ? make_binary(env, query_start, query_len)
        : make_binary(env, "", 0);

    // Build headers list: [{name_bin, value_bin}, ...]
    ERL_NIF_TERM headers_list = enif_make_list(env, 0);
    // Build in reverse order then... actually phr gives them in order,
    // but building a list prepends, so build backwards
    for (int i = (int)num_headers - 1; i >= 0; i--) {
        ERL_NIF_TERM name_bin = make_binary(env, headers[i].name, headers[i].name_len);
        ERL_NIF_TERM value_bin = make_binary(env, headers[i].value, headers[i].value_len);
        ERL_NIF_TERM pair = enif_make_tuple2(env, name_bin, value_bin);
        headers_list = enif_make_list_cell(env, pair, headers_list);
    }

    // Build result tuple
    ERL_NIF_TERM result = enif_make_tuple6(
        env,
        method_term,
        path_term,
        query_term,
        headers_list,
        enif_make_int(env, body_offset),
        enif_make_int(env, minor_version)
    );

    return enif_make_tuple2(env, atom_ok, result);
}

// --- parse_query_string/1 ---
//
// Splits on '&' and '=', percent-decodes keys and values.
// Returns: [{key_bin, value_bin}, ...]

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

// Percent-decode in-place, returns decoded length
static size_t percent_decode(const char* src, size_t src_len, char* dst) {
    size_t j = 0;
    for (size_t i = 0; i < src_len; i++) {
        if (src[i] == '%' && i + 2 < src_len) {
            int h = hex_digit(src[i+1]);
            int l = hex_digit(src[i+2]);
            if (h >= 0 && l >= 0) {
                dst[j++] = (char)(h * 16 + l);
                i += 2;
                continue;
            }
        }
        if (src[i] == '+') {
            dst[j++] = ' ';
        } else {
            dst[j++] = src[i];
        }
    }
    return j;
}

static ERL_NIF_TERM nif_parse_query_string(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary input;
    if (!enif_inspect_binary(env, argv[0], &input)) {
        return enif_make_badarg(env);
    }

    if (input.size == 0) {
        return enif_make_list(env, 0);
    }

    // Decode buffer — worst case same size as input
    char* decode_buf = enif_alloc(input.size);
    if (!decode_buf) return enif_make_badarg(env);

    const char* data = (const char*)input.data;
    size_t len = input.size;

    const char* p = data;
    const char* end = data + len;

    // Now build pairs in reverse (prepend to list = forward order if we
    // process from end to start). Let's just process forward and reverse.
    // Actually for simplicity, process from end to start:
    // Find segments from the end.

    // Simplest correct approach: process forward, prepend, then reverse
    ERL_NIF_TERM pairs = enif_make_list(env, 0);

    while (p < end) {
        // Find next '&'
        const char* amp = memchr(p, '&', end - p);
        const char* seg_end = amp ? amp : end;
        size_t seg_len = seg_end - p;

        if (seg_len > 0) {
            // Find '=' in segment
            const char* eq = memchr(p, '=', seg_len);

            const char* key_start = p;
            size_t key_len;
            const char* val_start;
            size_t val_len;

            if (eq) {
                key_len = eq - p;
                val_start = eq + 1;
                val_len = seg_end - val_start;
            } else {
                key_len = seg_len;
                val_start = "";
                val_len = 0;
            }

            // Percent-decode key
            size_t dk_len = percent_decode(key_start, key_len, decode_buf);
            ERL_NIF_TERM key_bin = make_binary(env, decode_buf, dk_len);

            // Percent-decode value
            size_t dv_len = percent_decode(val_start, val_len, decode_buf);
            ERL_NIF_TERM val_bin = make_binary(env, decode_buf, dv_len);

            ERL_NIF_TERM pair = enif_make_tuple2(env, key_bin, val_bin);
            pairs = enif_make_list_cell(env, pair, pairs);
        }

        p = seg_end + 1;
    }

    enif_free(decode_buf);

    // Reverse the list to get original order
    ERL_NIF_TERM reversed;
    if (!enif_make_reverse_list(env, pairs, &reversed)) {
        return pairs; // fallback
    }
    return reversed;
}

// --- NIF function table ---

static ErlNifFunc nif_funcs[] = {
    {"parse_request", 1, nif_parse_request, 0},
    {"parse_query_string", 1, nif_parse_query_string, 0}
};

ERL_NIF_INIT(Elixir.Rocket.HTTP, nif_funcs, load, NULL, NULL, NULL)

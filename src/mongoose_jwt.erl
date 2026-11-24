%% @doc Verification of JSON Web Tokens (RFC 7519) signed with a JWS (RFC 7515).
%%
%% Signatures are checked here instead of in jwerl, because jwerl:
%% <ul>
%%  <li>expects ECDSA signatures in ASN.1 DER, while JWS uses the fixed-width
%%      `R || S' form (RFC 7518, section 3.4), so it rejects every standard
%%      ES256, ES384 and ES512 token;</li>
%%  <li>compares HMAC digests with `==', which is not constant-time;</li>
%%  <li>does not check that the `alg' header matches the configured algorithm.</li>
%% </ul>
%% The time claims are checked here too, with a fixed allowance for clock skew.
%% Neither the token nor the key is ever included in an error.
%% @end
-module(mongoose_jwt).

-export([verify/3, header/1, algorithms/0, is_public_key/1]).

-include_lib("public_key/include/public_key.hrl").

-type algorithm() :: hs256 | hs384 | hs512 | rs256 | rs384 | rs512 | es256 | es384 | es512.
-type claims() :: #{binary() => term()}.
-type error_reason() :: invalid_token | wrong_algorithm | invalid_signature | invalid_key
                      | token_expired | token_not_yet_valid | token_issued_in_future.

-export_type([algorithm/0, claims/0, error_reason/0]).

%% Allowed difference between the clocks of the token issuer and this server
-define(CLOCK_SKEW_SECONDS, 60).

%% @doc The configuration names of the supported algorithms.
-spec algorithms() -> #{binary() => algorithm()}.
algorithms() ->
    #{<<"HS256">> => hs256, <<"RS256">> => rs256, <<"ES256">> => es256,
      <<"HS384">> => hs384, <<"RS384">> => rs384, <<"ES384">> => es384,
      <<"HS512">> => hs512, <<"RS512">> => rs512, <<"ES512">> => es512}.

%% @doc Decodes the token header, without verifying the token.
-spec header(binary()) -> {ok, map()} | {error, invalid_token}.
header(Token) ->
    case split(Token) of
        {ok, HeaderB64, _, _} -> decode_json(HeaderB64);
        {error, _} = Error -> Error
    end.

%% @doc Verifies the signature with `Key' and algorithm `Alg', then checks the
%% `exp', `nbf' and `iat' claims when they are present. Returns the claims, with binary names.
%% `Key' is the shared secret for the HS algorithms and a PEM-encoded public key
%% for the RS and ES algorithms.
-spec verify(binary(), algorithm(), binary()) -> {ok, claims()} | {error, error_reason()}.
verify(Token, Alg, Key) ->
    try do_verify(Token, Alg, Key)
    catch _:_ -> {error, invalid_token}
    end.

do_verify(Token, Alg, Key) ->
    maybe
        {ok, HeaderB64, PayloadB64, SigB64} ?= split(Token),
        {ok, Header} ?= decode_json(HeaderB64),
        ok ?= check_header_alg(Header, Alg),
        {ok, Sig} ?= base64url_decode(SigB64),
        SigningInput = <<HeaderB64/binary, ".", PayloadB64/binary>>,
        ok ?= verify_signature(Alg, Key, SigningInput, Sig),
        {ok, Claims} ?= decode_json(PayloadB64),
        true ?= is_map(Claims) orelse {error, invalid_token},
        ok ?= check_time_claims(Claims, erlang:system_time(second)),
        {ok, Claims}
    end.

split(Token) when is_binary(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [H, P, S] when H =/= <<>>, P =/= <<>>, S =/= <<>> -> {ok, H, P, S};
        _ -> {error, invalid_token}
    end;
split(_) ->
    {error, invalid_token}.

decode_json(B64) ->
    maybe
        {ok, Bin} ?= base64url_decode(B64),
        Json = json:decode(Bin),
        true ?= is_map(Json) orelse {error, invalid_token},
        {ok, Json}
    else
        _ -> {error, invalid_token}
    end.

base64url_decode(B64) ->
    try {ok, base64:decode(B64, #{mode => urlsafe, padding => false})}
    catch _:_ -> {error, invalid_token}
    end.

%% The algorithm is taken from the configuration only. A token naming another one
%% (for example "none", or HS256 with an RSA public key as the secret) is rejected.
check_header_alg(#{<<"alg">> := Name}, Alg) ->
    case maps:find(Name, algorithms()) of
        {ok, Alg} -> ok;
        _ -> {error, wrong_algorithm}
    end;
check_header_alg(_, _) ->
    {error, invalid_token}.

verify_signature(Alg, Key, SigningInput, Sig) ->
    case alg_type(Alg) of
        {hmac, Digest} -> verify_hmac(Digest, Key, SigningInput, Sig);
        {rsa, Digest} -> verify_rsa(Digest, Key, SigningInput, Sig);
        {ecdsa, Digest, Size} -> verify_ecdsa(Digest, Size, Key, SigningInput, Sig)
    end.

alg_type(hs256) -> {hmac, sha256};
alg_type(hs384) -> {hmac, sha384};
alg_type(hs512) -> {hmac, sha512};
alg_type(rs256) -> {rsa, sha256};
alg_type(rs384) -> {rsa, sha384};
alg_type(rs512) -> {rsa, sha512};
alg_type(es256) -> {ecdsa, sha256, 32};
alg_type(es384) -> {ecdsa, sha384, 48};
alg_type(es512) -> {ecdsa, sha512, 66}.

verify_hmac(_Digest, <<>>, _SigningInput, _Sig) ->
    {error, invalid_key};
verify_hmac(Digest, Key, SigningInput, Sig) ->
    Expected = crypto:mac(hmac, Digest, Key, SigningInput),
    %% crypto:hash_equals/2 needs equal sizes, and the size is not secret
    case byte_size(Sig) =:= byte_size(Expected) andalso crypto:hash_equals(Sig, Expected) of
        true -> ok;
        false -> {error, invalid_signature}
    end.

verify_rsa(Digest, Key, SigningInput, Sig) ->
    case public_key(Key) of
        {ok, #'RSAPublicKey'{} = PubKey} ->
            bool_result(public_key:verify(SigningInput, Digest, Sig, PubKey));
        _ ->
            {error, invalid_key}
    end.

%% JWS ECDSA signatures are R and S, each padded to the curve size (RFC 7518, section 3.4)
verify_ecdsa(Digest, Size, Key, SigningInput, Sig) when byte_size(Sig) =:= 2 * Size ->
    case public_key(Key) of
        {ok, {#'ECPoint'{}, _} = PubKey} ->
            <<R:Size/unit:8, S:Size/unit:8>> = Sig,
            DerSig = public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{r = R, s = S}),
            bool_result(public_key:verify(SigningInput, Digest, DerSig, PubKey));
        _ ->
            {error, invalid_key}
    end;
verify_ecdsa(_Digest, _Size, _Key, _SigningInput, _Sig) ->
    {error, invalid_signature}.

bool_result(true) -> ok;
bool_result(false) -> {error, invalid_signature}.

%% @doc Whether `Pem' holds exactly one RSA or EC public key (and no private key).
-spec is_public_key(binary()) -> boolean().
is_public_key(Pem) ->
    case public_key(Pem) of
        {ok, _} -> true;
        error -> false
    end.

%% Only public keys are accepted. A private key would be a configuration mistake
%% that leaks the key to everyone who can read the configuration.
public_key(Pem) ->
    try public_key:pem_decode(Pem) of
        [{Type, _, not_encrypted} = Entry] when Type =:= 'SubjectPublicKeyInfo';
                                                Type =:= 'RSAPublicKey' ->
            case public_key:pem_entry_decode(Entry) of
                #'RSAPublicKey'{} = Key -> {ok, Key};
                {#'ECPoint'{}, _} = Key -> {ok, Key};
                _ -> error
            end;
        _ ->
            error
    catch _:_ ->
            error
    end.

check_time_claims(Claims, Now) ->
    Checks = [{<<"exp">>, fun(Exp) -> Now < Exp + ?CLOCK_SKEW_SECONDS end, token_expired},
              {<<"nbf">>, fun(Nbf) -> Nbf =< Now + ?CLOCK_SKEW_SECONDS end, token_not_yet_valid},
              {<<"iat">>, fun(Iat) -> Iat =< Now + ?CLOCK_SKEW_SECONDS end, token_issued_in_future}],
    check_time_claims(Claims, Checks, ok).

check_time_claims(_Claims, [], Result) ->
    Result;
check_time_claims(Claims, [{Name, Check, Error} | Checks], ok) ->
    case maps:find(Name, Claims) of
        error -> check_time_claims(Claims, Checks, ok);
        {ok, Value} when is_number(Value) ->
            case Check(Value) of
                true -> check_time_claims(Claims, Checks, ok);
                false -> {error, Error}
            end;
        {ok, _} -> {error, invalid_token}
    end.

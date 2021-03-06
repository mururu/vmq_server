-module(vmq_ssl_SUITE).
-export([
         %% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([connect_no_auth_test/1,
         connect_no_auth_wrong_ca_test/1,
         connect_cert_auth_test/1,
         connect_cert_auth_without_test/1,
         connect_cert_auth_expired_test/1,
         connect_cert_auth_revoked_test/1,
         connect_cert_auth_crl_test/1,
         connect_identity_test/1,
         connect_no_identity_test/1]).

-export([hook_preauth_success/5]).

%% ===================================================================
%% common_test callbacks
%% ===================================================================
init_per_suite(_Config) ->
    cover:start(),
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(Case, Config) ->
    vmq_test_utils:setup(),
    case {lists:member(Case, all_no_auth()),
          lists:member(Case, all_cert_auth()),
          lists:member(Case, all_cert_auth_revoked()),
          lists:member(Case, all_cert_auth_identity())} of
        {true, _, _, _} ->
            {ok, _} = vmq_server_cmd:set_config(allow_anonymous, true),
            {ok, _} = vmq_server_cmd:listener_start(1888, [{ssl, true},
                                                           {nr_of_acceptors, 5},
                                                           {cafile, "../../test/ssl/all-ca.crt"},
                                                           {certfile, "../../test/ssl/server.crt"},
                                                           {keyfile, "../../test/ssl/server.key"},
                                                           {tls_version, "tlsv1.2"}]);
        {_, true, _, _} ->
            {ok, _} = vmq_server_cmd:set_config(allow_anonymous, true),
            {ok, _} = vmq_server_cmd:listener_start(1888, [{ssl, true},
                                                           {nr_of_acceptors, 5},
                                                           {cafile, "../../test/ssl/all-ca.crt"},
                                                           {certfile, "../../test/ssl/server.crt"},
                                                           {keyfile, "../../test/ssl/server.key"},
                                                           {tls_version, "tlsv1.2"},
                                                           {require_certificate, true}]);
        {_, _, true, _} ->
            {ok, _} = vmq_server_cmd:set_config(allow_anonymous, true),
            {ok, _} = vmq_server_cmd:listener_start(1888, [{ssl, true},
                                                           {nr_of_acceptors, 5},
                                                           {cafile, "../../test/ssl/all-ca.crt"},
                                                           {certfile, "../../test/ssl/server.crt"},
                                                           {keyfile, "../../test/ssl/server.key"},
                                                           {tls_version, "tlsv1.2"},
                                                           {require_certificate, true},
                                                           {crlfile, "../../test/ssl/crl.pem"}]);
        {_, _, _, true} ->
            {ok, _} = vmq_server_cmd:set_config(allow_anonymous, false),
            {ok, _} = vmq_server_cmd:listener_start(1888, [{ssl, true},
                                                           {nr_of_acceptors, 5},
                                                           {cafile, "../../test/ssl/all-ca.crt"},
                                                           {certfile, "../../test/ssl/server.crt"},
                                                           {keyfile, "../../test/ssl/server.key"},
                                                           {tls_version, "tlsv1.2"},
                                                           {require_certificate, true},
                                                           {crlfile, "../../test/ssl/crl.pem"},
                                                           {use_identity_as_username, true}]),
            vmq_plugin_mgr:enable_module_plugin(
              auth_on_register, ?MODULE, hook_preauth_success, 5)
    end,
    Config.

end_per_testcase(_, Config) ->
    vmq_test_utils:teardown(),
    Config.

all() ->
    all_no_auth()
    ++ all_cert_auth()
    ++ all_cert_auth_revoked()
    ++ all_cert_auth_identity().

all_no_auth() ->
    [connect_no_auth_test,
     connect_no_auth_wrong_ca_test].

all_cert_auth() ->
    [connect_cert_auth_test,
     connect_cert_auth_without_test,
     connect_cert_auth_expired_test].

all_cert_auth_revoked() ->
    [connect_cert_auth_revoked_test,
     connect_cert_auth_crl_test].

all_cert_auth_identity() ->
    [connect_identity_test,
     connect_no_identity_test].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Actual Tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connect_no_auth_test(_) ->
    Connect = packet:gen_connect("connect-success-test", [{keepalive, 10}]),
    Connack = packet:gen_connack(0),
    {ok, SSock} = ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {cacerts, load_cacerts()}]),
    ok = ssl:send(SSock, Connect),
    ok = packet:expect_packet(ssl, SSock, "connack", Connack),
    ok, ssl:close(SSock).

connect_no_auth_wrong_ca_test(_) ->
    assert_error_or_closed({error,{tls_alert,"unknown ca"}},
                  ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacertfile, "../../test/ssl/test-alt-ca.crt"}])).

connect_cert_auth_test(_) ->
    Connect = packet:gen_connect("connect-success-test", [{keepalive, 10}]),
    Connack = packet:gen_connack(0),
    {ok, SSock} = ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()},
                               {certfile, "../../test/ssl/client.crt"},
                               {keyfile, "../../test/ssl/client.key"}]),
    ok = ssl:send(SSock, Connect),
    ok = packet:expect_packet(ssl, SSock, "connack", Connack),
    ok = ssl:close(SSock).

connect_cert_auth_without_test(_) ->
    assert_error_or_closed({error,{tls_alert,"handshake failure"}},
                  ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()}])).

connect_cert_auth_expired_test(_) ->
    assert_error_or_closed({error,{tls_alert,"certificate expired"}},
                  ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()},
                               {certfile, "../../test/ssl/client-expired.crt"},
                               {keyfile, "../../test/ssl/client.key"}])).

connect_cert_auth_revoked_test(_) ->
    assert_error_or_closed({error,{tls_alert,"certificate revoked"}},
                  ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()},
                               {certfile, "../../test/ssl/client-revoked.crt"},
                               {keyfile, "../../test/ssl/client.key"}])).

connect_cert_auth_crl_test(_) ->
    Connect = packet:gen_connect("connect-success-test", [{keepalive, 10}]),
    Connack = packet:gen_connack(0),
    {ok, SSock} = ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()},
                               {certfile, "../../test/ssl/client.crt"},
                               {keyfile, "../../test/ssl/client.key"}]),
    ok = ssl:send(SSock, Connect),
    ok = packet:expect_packet(ssl, SSock, "connack", Connack),
    ok = ssl:close(SSock).

connect_identity_test(_) ->
    Connect = packet:gen_connect("connect-success-test", [{keepalive, 10}]),
    Connack = packet:gen_connack(0),
    {ok, SSock} = ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()},
                               {certfile, "../../test/ssl/client.crt"},
                               {keyfile, "../../test/ssl/client.key"}]),
    ok = ssl:send(SSock, Connect),
    ok = packet:expect_packet(ssl, SSock, "connack", Connack),
    ok = ssl:close(SSock).

connect_no_identity_test(_) ->
    assert_error_or_closed({error,{tls_alert,"handshake failure"}},
                  ssl:connect("localhost", 1888,
                              [binary, {active, false}, {packet, raw},
                               {verify, verify_peer},
                               {cacerts, load_cacerts()}])).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hook_preauth_success(_, {"", "connect-success-test"}, {preauth, "test client"}, undefined, _) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Helper
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-compile({inline, [assert_error_or_closed/2]}).
assert_error_or_closed(Error, Val) ->
    true = case Val of
               {error, closed} -> true;
               Error -> true;
               {ok, SSLSocket} = E ->
                   ssl:close(SSLSocket),
                   E;
               Other -> Other
           end, true.

load_cacerts() ->
    IntermediateCA = "../../test/ssl/test-signing-ca.crt",
    RootCA = "../../test/ssl/test-root-ca.crt",
    load_cert(RootCA) ++ load_cert(IntermediateCA).

load_cert(Cert) ->
    {ok, Bin} = file:read_file(Cert),
    case filename:extension(Cert) of
        ".der" ->
            %% no decoding necessary
            [Bin];
        _ ->
            %% assume PEM otherwise
            Contents = public_key:pem_decode(Bin),
            [DER || {Type, DER, Cipher} <-
                    Contents, Type == 'Certificate',
                    Cipher == 'not_encrypted']
    end.

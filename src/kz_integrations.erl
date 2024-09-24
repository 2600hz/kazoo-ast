%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2015-2023, 2600Hz
%%% @doc Generate schema for Account and System configurations.
%%% @author James Aimonetti
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_integrations).

-export([process/2]).

-include_lib("ast/include/kz_ast.hrl").

-spec process(file:filename_all(), [file:filename_all()]) -> 'ok'.
process(IntegrationFile, Sources) ->
    Modules = to_modules(Sources),
    {'ok', _Pid} = xref:start(?MODULE, {'xref_mode', 'modules'}),

    [load_dir(Dir)
     || Dir <- code:get_path(),
        should_add_dir(Dir)
    ],

    Integrations = read_integrations(IntegrationFile),

    io:format('user', "processing ", []),
    Updated = lists:foldl(fun module_integration/2, Integrations, Modules),
    io:format('user', " done~n", []),

    case Integrations =:= Updated of
        'true' -> 'ok';
        'false' ->
            write_integrations(IntegrationFile, Updated)
    end,
    _ = xref:stop(?MODULE),
    'ok'.

load_dir(Dir) ->
    {'ok', AppName} = xref:add_application(?MODULE, filename:dirname(Dir)),
    'ok' = application:load(AppName).

module_integration(Module, Integrations) ->
    io:format('user', ".", []),
    Module = kz_module:ensure_loaded(Module),
    {'ok', _ModApp} = application:get_application(Module),

    {'ok', RemoteModules} = xref:analyze(?MODULE, {'module_call', Module}),

    ModuleIntegrations = maps:get(Module, Integrations, #{}),
    RRefs = maps:get('called_modules', ModuleIntegrations, []),

    RemoteRefs = [{RemoteApp, RemoteMod}
                  || RemoteMod <- RemoteModules,
                     RemoteMod =:= kz_module:ensure_loaded(RemoteMod),
                     {'ok', RemoteApp} <- [application:get_application(RemoteMod)]
                 ] ++ RRefs,
    maps:put(Module
            ,ModuleIntegrations#{called_modules => lists:usort(RemoteRefs)
                                ,integration_app => integration_app(Module, ModuleIntegrations)
                                }
            ,Integrations
            ).

integration_app(Module, #{integration_app := 'undefined'}) ->
    integration_app(Module, #{});
integration_app(_Module, #{integration_app := App}) -> App;
integration_app(Module, _) ->
    Attributes = Module:module_info('attributes'),
    case props:get_value('integration', Attributes) of
        'undefined' -> 'undefined';
        [App] -> App
    end.

to_modules(Sources) ->
    [to_module(Source) || Source <- Sources].

to_module(Source) ->
    kz_term:to_atom(filename:basename(Source, ".beam"), 'true').

should_add_dir(".") -> 'false';
should_add_dir(Dir) ->
    'nomatch' =/= re:run(Dir, "applications|/core").

read_integrations(IntegrationsFile) ->
    case file:consult(IntegrationsFile) of
        {'error', 'enoent'} -> #{};
        {'ok', []} -> #{};
        {'ok', [Integrations]} -> maps:from_list(Integrations)
    end.

write_integrations(File, Integrations) ->
    io:format("writing integrations to ~s~n", [File]),
    'ok' = filelib:ensure_dir(File),
    Data = io_lib:format("~p.", [maps:to_list(Integrations)]),
    'ok' = file:write_file(File, Data).

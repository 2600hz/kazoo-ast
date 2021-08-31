%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2018-2019, 2600Hz
%%% @doc Kazoo document accessors builder.
%%% @author James Aimonetti
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_builders).

-export([build_accessors/0, build_accessors/1
        ,build_accessor/1, build_accessor/2
        ]).

-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kazoo_json.hrl").

-spec build_accessors() -> 'ok'.
build_accessors() ->
    build_accessors('crossbar').

-spec build_accessors(atom() | string()) -> 'ok'.
build_accessors(AppName) ->
    App = kz_term:to_atom(AppName, 'true'),
    PrivDir = code:priv_dir(App),
    io:format("building accessors: "),
    'ok' = filelib:fold_files(kz_term:to_list(kz_ast_util:schema_path(<<>>, PrivDir))
                             ,"^[a-z_]+\\.json$"
                             ,'false'
                             ,fun(Path, Acc) ->
                                      build_accessor(App, Path, Acc)
                              end
                             ,'ok'
                             ),
    io:format(" done~n").

-spec build_accessor(file:filename()) -> 'ok'.
build_accessor(SchemaPath) ->
    build_accessor('crossbar', SchemaPath).

-spec build_accessor(App :: atom() | string(), file:filename()) -> 'ok'.
build_accessor(App, SchemaPath) ->
    build_accessor(kz_term:to_atom(App, 'true'), SchemaPath, 'ok').

-spec build_accessor(atom(), file:filename(), 'ok') -> 'ok'.
build_accessor(App, SchemaPath, 'ok') ->
    io:format("."),
    {'ok', SchemaJObj} = kz_json_schema:fload(SchemaPath),
    SchemaId = kz_doc:id(SchemaJObj),

    BaseModule = base_module(SchemaId),

    case accessors_from_properties(App, kz_json:get_json_value(<<"properties">>, SchemaJObj)) of
        'undefined' -> 'ok';
        {Exports, Accessors} ->
            {PatternExports, PatternAccessors} = accessors_from_patterns(App, kz_json:get_json_value(<<"patternProperties">>, SchemaJObj)),

            save_module(App, SchemaId, [BaseModule
                                       ,lists:reverse(Exports) ++ lists:reverse(PatternExports), "\n"
                                       ,base_includes()
                                       ,base_types(kz_doc:id(SchemaJObj))
                                       ,lists:reverse(Accessors) ++ lists:reverse(PatternAccessors)
                                       ])
    end.

-spec fload_schema(atom(), kz_term:ne_binary()) ->
          {'ok', kz_json:object()} |
          {'error', 'not_found' | file:posix()}.
fload_schema(App, Schema) ->
    PrivDir = code:priv_dir(App),
    SchemaPath = filename:join([PrivDir, "couchdb", "schemas", maybe_add_ext(Schema)]),
    case filelib:is_regular(SchemaPath) of
        'true' -> kz_json_schema:fload(SchemaPath);
        'false'->
            %% let read from crossbar if not found in the app priv folder
            kz_json_schema:fload(Schema)
    end.

-spec maybe_add_ext(kz_term:ne_binary()) -> kz_term:ne_binary().
maybe_add_ext(Schema) ->
    case filename:extension(Schema) of
        <<".json">> -> Schema;
        _Ext -> <<Schema/binary, ".json">>
    end.

save_module('crossbar', Id, FileContents) ->
    SrcDir = code:lib_dir('kazoo_documents', 'src'),
    Filename = filename:join([SrcDir, <<"kzd_", Id/binary, ".erl.src">>]),
    'ok' = file:write_file(Filename, FileContents);
save_module(App, Id, FileContents) ->
    SrcDir = code:lib_dir(App, 'src'),
    Filename = filename:join([SrcDir, <<"kzd_", Id/binary, ".erl.src">>]),
    'ok' = file:write_file(Filename, FileContents).

accessors_from_patterns(_App, 'undefined') ->
    {[], []};
accessors_from_patterns(App, PatternProperties) ->
    {Accessors, _} = kz_json:foldl(fun(Pat, Prop, Acc) -> accessor_from_pattern(App, Pat, Prop, Acc) end
                                  ,{{[], []}, []}
                                  ,PatternProperties
                                  ),
    Accessors.

accessor_from_pattern(_App, <<"^_", _/binary>>, _Properties, Acc) -> Acc;
accessor_from_pattern(_App, <<"^_pvt", _/binary>>, _Properties, Acc) -> Acc;
accessor_from_pattern(App, _Pattern, Properties, {Acc, Path}) ->
    PatternPath = pattern_path(Path, Properties),
    Acc1 = accessor_from_pattern(App, PatternPath, key_from_path(PatternPath), Properties, Acc),
    {Acc1, PatternPath}.

pattern_path([], Properties) ->
    case kz_json:get_ne_binary_value(<<"name">>, Properties) of
        'undefined' -> [];
        Name -> [Name]
    end;
pattern_path(Path, Properties) ->
    case kz_json:get_ne_binary_value(<<"name">>, Properties) of
        'undefined' -> Path;
        Name ->
            [_|Rest] = lists:reverse(Path),
            lists:reverse([Name | Rest])
    end.

accessor_from_pattern(App, Path, Key, Properties, {Exports, Accessors}) ->
    AccessorName = clean_name(Path),
    {add_pattern_exports(AccessorName, Key, Exports)
    ,add_pattern_accessors(App, AccessorName, Key, Properties, Accessors)
    }.

key_from_path([]) ->
    <<"index">>;
key_from_path([_|_]=Path) ->
    key_from_parent(lists:last(Path)).

key_from_parent(<<"children">>) ->
    <<"child">>;
key_from_parent(<<"i18n">>) ->
    <<"language">>;
key_from_parent(<<"audit">>) ->
    <<"account_id">>;
key_from_parent(<<"plan">>) ->
    <<"plan_name">>;
key_from_parent(<<"node">>=Node) ->
    Node;
key_from_parent(<<"zone">>=Zone) ->
    Zone;
key_from_parent(Parent) ->
    case kz_binary:strip_right(Parent, <<"s">>) of
        Parent -> kz_binary:join([Parent, <<"index">>], <<"_">>);
        Singular -> Singular
    end.

accessors_from_properties(_App, 'undefined') -> 'undefined';
accessors_from_properties(App, Properties) ->
    kz_json:foldl(fun(Prop, Schema, Acc) -> accessor_from_properties(App, Prop, Schema, Acc) end
                 ,{base_exports(), base_accessors()}
                 ,Properties
                 ).

accessor_from_properties(App, ?NE_BINARY=Property, Schema, Acc) ->
    accessor_from_properties(App, [Property], Schema, Acc);
accessor_from_properties(App, Property, Schema, {Exports, Accessors}) ->
    Acc = {add_exports(clean_name(Property), Exports)
          ,add_accessors(App, clean_name(Property), Schema, Accessors)
          },
    maybe_add_sub_properties(App, Property, Schema, Acc, kz_json:get_value(<<"type">>, Schema)).

maybe_add_sub_properties(App, Property, Schema, Acc0, <<"object">>) ->
    Acc1 = kz_json:foldl(fun(SubProperty, SubSchema, Acc) ->
                                 add_sub_property(App, SubProperty, SubSchema, Acc, Property)
                         end
                        ,Acc0
                        ,kz_json:get_json_value(<<"properties">>, Schema, kz_json:new())
                        ),
    {Acc2, _} = kz_json:foldl(fun(Pat, Prop, Acc) -> accessor_from_pattern(App, Pat, Prop, Acc) end
                             ,{Acc1, Property}
                             ,kz_json:get_json_value(<<"patternProperties">>, Schema, kz_json:new())
                             ),
    Acc2;
maybe_add_sub_properties(_App, _Property, _Schema, Acc, _Type) -> Acc.

add_sub_property(App, SubProperty, SubSchema, Acc, ParentProperty) ->
    accessor_from_properties(App, ParentProperty ++ [SubProperty], SubSchema, Acc).

getter_name([], Key) ->
    kz_term:to_lower_binary(Key);
getter_name([_Parent], Key) ->
    kz_term:to_lower_binary(Key);
getter_name([_|_]=Path, Key) ->
    kz_binary:join([getter_name(lists:droplast(Path)), clean_name(Key)], <<"_">>).

getter_name([_|_]=Properties) ->
    kz_binary:join([getter_name(P) || P <- Properties], <<"_">>);
getter_name(Property) ->
    kz_term:to_lower_binary(Property).

add_exports(Property, Exports) ->
    Getter = getter_name(Property),
    [["-export([", Getter, "/1, ", Getter, "/2, set_", Getter, "/2]).\n"]
    | Exports
    ].

add_pattern_exports(Property, Key, Exports) ->
    Getter = getter_name(Property, Key),
    [["-export([", Getter, "/2, ", Getter, "/3, set_", Getter, "/3]).\n"]
    | Exports
    ].

add_accessors(App, Property, Schema, Accessors) ->
    {JSONGetterFun, ReturnType} = json_getter_fun(App, Schema),
    Default = default_value(Schema, JSONGetterFun),

    Getter = getter_name(Property),
    SetVar = kz_ast_util:smash_snake(kz_binary:ucfirst(Getter), <<>>),
    JSONPath = json_path(Property),

    [["\n"
     ,"-spec ", Getter, "(doc()) -> ", default_return_type(ReturnType, Default), ".\n"
     ,Getter, "(Doc) ->\n"
     ,"    ", Getter, "(Doc, ", Default, ").\n"
     ,"\n"
     ,"-spec ", Getter, "(doc(), Default) -> ", ReturnType, " | Default.\n"
     ,Getter, "(Doc, Default) ->\n"
     ,"    kz_json:", JSONGetterFun, "(", JSONPath, ", Doc, Default).\n"
     ,"\n"
     ,"-spec set_", Getter, "(doc(), ", ReturnType, ") -> doc().\n"
     ,"set_", Getter, "(Doc, ", SetVar, ") ->\n"
     ,"    kz_json:set_value(", JSONPath, ", ", SetVar, ", Doc).\n"
     ]
    | Accessors
    ].

add_pattern_accessors(App, ParentProperty, Key, Schema, Accessors) ->
    {JSONGetterFun, ReturnType} = json_getter_fun(App, Schema),
    Default = default_value(Schema, JSONGetterFun),

    Getter = getter_name(ParentProperty, Key),
    GetterKey = kz_ast_util:smash_snake(Key, <<>>),
    SetVar = <<"Value">>,
    JSONPath = json_path(ParentProperty, GetterKey),

    [["\n"
     ,"-spec ", Getter, "(doc(), kz_json:key()) -> ", default_return_type(ReturnType, Default), ".\n"
     ,Getter, "(Doc, ", GetterKey, ") ->\n"
     ,"    ", Getter, "(Doc, ", GetterKey, ", ", Default, ").\n"
     ,"\n"
     ,"-spec ", Getter, "(doc(), kz_json:key(), Default) -> ", ReturnType, " | Default.\n"
     ,Getter, "(Doc, ", GetterKey, ", Default) ->\n"
     ,"    kz_json:", JSONGetterFun, "(", JSONPath, ", Doc, Default).\n"
     ,"\n"
     ,"-spec set_", Getter, "(doc(), kz_json:key(), ", ReturnType, ") -> doc().\n"
     ,"set_", Getter, "(Doc, ", GetterKey, ", ", SetVar, ") ->\n"
     ,"    kz_json:set_value(", JSONPath, ", ", SetVar, ", Doc).\n"
     ]
    | Accessors
    ].

json_path([], Var) ->
    ["[", Var, "]"];
json_path([Parent | Properties], Var) ->
    ["[", json_path(Parent)
    ,[[", ", json_path(Property)] || Property <- Properties]
    ,", ", Var
    ,"]"
    ].

json_path([Parent|Properties]) ->
    ["[", json_path(Parent)
    ,[[", ", json_path(Property)] || Property <- Properties]
    ,"]"
    ];
json_path(Property) ->
    ["<<\"", Property, "\">>"].

json_getter_fun(App, Schema) ->
    json_getter_fun(App, Schema, kz_json:get_value(<<"type">>, Schema)).

json_getter_fun(_App, _Schema, <<"object">>) ->
    {"get_json_value", "kz_json:object()"};
json_getter_fun(_App, _Schema, <<"boolean">>) ->
    {"get_boolean_value", "boolean()"};
json_getter_fun(App, Schema, <<"array">>) ->
    {"get_list_value", list_return_subtype(App, Schema)};
json_getter_fun(_App, _Schema, <<"integer">>) ->
    {"get_integer_value", "integer()"};
json_getter_fun(_App, _Schema, <<"number">>) ->
    {"get_float_value", "number()"};
json_getter_fun(App, Schema, 'undefined') ->
    case kz_json:get_value(<<"$ref">>, Schema) of
        'undefined' ->
            case kz_json:get_list_value(<<"oneOf">>, Schema) of
                undefined ->
                    {"get_value", "any()"};
                OneOf ->
                    Types = [oneof(Type) || Type <- OneOf],
                    json_getter_fun(App, Schema, lists:usort(Types))
            end;
        Ref ->
            {'ok', RefSchema} = fload_schema(App, Ref),
            json_getter_fun(App, RefSchema, kz_json:get_value(<<"type">>, RefSchema))
    end;
json_getter_fun(_App, Schema, <<"string">>) ->
    case kz_json:get_integer_value(<<"minLength">>, Schema) of
        N when is_integer(N), N > 0 ->
            {"get_ne_binary_value", "kz_term:ne_binary()"};
        _ ->
            {"get_binary_value", "binary()"}
    end;
json_getter_fun(_App, _Schema, [{<<"array">>, <<"string">>}, <<"string">>]=_Type) ->
    {"get_ne_binary_or_binaries", "kz_term:ne_binary_or_binaries()"};
json_getter_fun(_App, _Schema, [_|_]=_Type) ->
    {"get_value", "any()"}; %% composite type
json_getter_fun(_App, _Schema, _Type) ->
    {"get_value", "any()"}.

list_return_subtype(App, Schema) ->
    list_return_subtype(App, Schema, kz_json:get_value([<<"items">>, <<"type">>], Schema)).

oneof(OneOf) ->
    case kz_json:get_value(<<"type">>, OneOf) of
        <<"array">> -> {<<"array">>, kz_json:get_value([<<"items">>, <<"type">>], OneOf)};
        Type -> Type
    end.

list_return_subtype(App, Schema, 'undefined') ->
    case kz_json:get_value([<<"items">>, <<"$ref">>], Schema) of
        'undefined' -> "list()";
        Ref ->
            {'ok', RefSchema} = fload_schema(App, Ref),
            list_return_subtype(App, RefSchema, kz_json:get_value(<<"type">>, RefSchema))
    end;
list_return_subtype(_App, _Schema, <<"string">>) -> "kz_term:ne_binaries()";
list_return_subtype(_App, _Schema, <<"integer">>) -> "kz_term:integers()";
list_return_subtype(_App, _Schema, <<"number">>) -> "[number()]";
list_return_subtype(_App, _Schema, <<"object">>) -> "kz_json:objects()";
list_return_subtype(_App, _Schema, _Type) ->
    "list()".

default_value(Schema, JSONGetterFun) ->
    default_value_str(JSONGetterFun, kz_json:get_value(<<"default">>, Schema)).

default_value_str(_JSONGetterFun, 'undefined') ->
    "'undefined'";
default_value_str("get_ne_binary_value", Default) ->
    ["<<\"", Default, "\">>"];
default_value_str("get_binary_value", Default) ->
    ["<<\"", Default, "\">>"];
default_value_str("get_list_value", []) ->
    "\[\]";
default_value_str(_JSONGetterFun, ?EMPTY_JSON_OBJECT) ->
    "kz_json:new()";
default_value_str(_JSONGetterFun, Default) ->
    kz_term:to_binary(Default).

default_return_type("kz_json:" ++ Type, "'undefined'") ->
    "kz_term:api_" ++ Type;
default_return_type("any()", _) -> "any()";
default_return_type("kz_term:" ++ Type, "'undefined'") ->
    ["kz_term:api_" | Type];
default_return_type(Type, "'undefined'") ->
    ["kz_term:api_" | Type];
default_return_type(Type, _Default) -> Type.


base_module(SchemaName) ->
    Name = clean_name(SchemaName),
    module_comment(Name) ++ ["-", "module(kzd_"] ++ [Name] ++ [").\n"].

module_comment(Name) ->
    {Year, _, _} = erlang:date(),
    ["%%%-----------------------------------------------------------------------------\n"
    ,"%%% @copyright (C) 2010-" ++ kz_term:to_list(Year) ++ ", 2600Hz\n"
    ,"%%% @doc Accessors for `" ++ [Name] ++ "' document.\n"
    ,"%%% @end\n"
    ,"%%%-----------------------------------------------------------------------------\n"].

clean_name([]) -> [];
clean_name([_|_]=Names) ->
    [clean_name(Name) || Name <- Names];
clean_name(Name) ->
    binary:replace(Name, <<"-">>, <<"_">>, ['global']).

base_exports() ->
    ["\n"
     "-export([new/0]).\n"
    ].

base_includes() ->
    ["\n"
     "-include(\"kz_documents.hrl\").\n"
    ].

base_types(SchemaId) ->
    ["\n"
     "-type doc() :: kz_json:object().\n"
     "-export_type([doc/0]).\n"
     "\n"
     "-define(SCHEMA, <<\"", SchemaId, "\">>).\n"
    ].

base_accessors() ->
    ["\n"
     "-spec new() -> doc().\n"
     "new() ->\n"
     "    kz_json_schema:default_object(?SCHEMA).\n"
    ].

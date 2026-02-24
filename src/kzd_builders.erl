%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2018-2023, 2600Hz
%%% @doc Kazoo document accessors builder.
%%% @author James Aimonetti
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_builders).

-export([build_accessors/0
        ,build_accessor/1
        ]).

-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kazoo_json.hrl").
-include_lib("kazoo_stdlib/include/kz_log.hrl").

-spec build_accessors() -> 'ok'.
build_accessors() ->
    ?LOG_DEBUG("building accessors: "),
    'ok' = filelib:fold_files(kz_term:to_list(kz_ast_util:schema_path(<<>>))
                             ,"^[a-z_.]+\\.json$"
                             ,'false'
                             ,fun build_accessor/2
                             ,'ok'
                             ),
    ?LOG_DEBUG(" done~n").

-spec build_accessor(file:filename()) -> 'ok'.
build_accessor(SchemaPath) ->
    build_accessor(SchemaPath, 'ok').

-spec build_accessor(file:filename(), 'ok') -> 'ok'.
build_accessor(SchemaPath, 'ok') ->
    ?LOG_DEBUG("."),
    {'ok', SchemaJObj} = kz_json_schema:fload(SchemaPath),
    SchemaId = kz_doc:id(SchemaJObj),
    build_accessor_from_schema(SchemaJObj, SchemaId).

build_accessor_from_schema(_SchemaJObj, <<"system_config.", _/binary>>) -> 'ok';
build_accessor_from_schema(_SchemaJObj, <<"account_config.", _/binary>>) -> 'ok';
build_accessor_from_schema(_SchemaJObj, <<"callflows.", _/binary>>) -> 'ok';
build_accessor_from_schema(SchemaJObj, SchemaId) ->
    BaseModule = base_module(SchemaId),

    case build_schema_accessors(SchemaJObj) of
        'undefined' -> 'ok';
        {Exports, Accessors} ->
            save_module(SchemaId, [BaseModule
                                  ,lists:sort(Exports), "\n"
                                  ,base_includes()
                                  ,base_types(kz_doc:id(SchemaJObj))
                                  ,lists:sort(Accessors)
                                  ])
    end.

build_schema_accessors(SchemaJObj) ->
    erlang:put('propertyPath', []),
    reset_property_counter(),
    {Exports, Accessors} = build_schema_accessors(SchemaJObj, {[], []}),
    case property_count() of
        0 -> 'undefined';
        _Else -> {Exports ++ base_exports(), Accessors ++ base_accessors()}
    end.
%% build_schema_accessors(SchemaJObj, {base_exports(), base_accessors()}).

build_schema_accessors(SchemaJObj, Acc) ->
    build_schema_accessors(SchemaJObj, Acc, []).

build_schema_accessors(SchemaJObj, Acc, ParentProperty) ->
    kz_json:foldl(build_schema_accessors_fold_fun(SchemaJObj, ParentProperty), Acc, SchemaJObj).

build_schema_accessors_fold_fun(SchemaJObj, ParentProperty) ->
    fun(Key, Value, Acc) ->
            erlang:put('topschema', SchemaJObj),
            build_schema_accessor(Key, Value, SchemaJObj, Acc, ParentProperty)
    end.

build_schema_accessor(<<"properties">>, Properties, _SchemaJObj, Acc, ParentProperty) ->
    kz_json:foldl(from_properties(ParentProperty), Acc, Properties);
build_schema_accessor(<<"patternProperties">>, PatternProperties, SchemaJObj, Acc, ParentProperty) ->
    build_from_pattern(PatternProperties, SchemaJObj, Acc, ParentProperty);
build_schema_accessor(<<"$ref">>, Reference, SchemaJObj, Acc, ParentProperty) ->
    RefSchema = json_ref_schema(SchemaJObj, Reference),
    build_schema_accessors(RefSchema, Acc, ParentProperty);
build_schema_accessor(<<"allOf">>, Schemas, _SchemaJObj, Acc, ParentProperty) ->
    lists:foldl(from_allof(ParentProperty), Acc, Schemas);
build_schema_accessor(_Key, _Value, _SchemaJObj, Acc, _ParentProperty) -> Acc.

from_allof(ParentProperty) ->
    fun(Schema, Acc) ->
            build_schema_accessors(Schema, Acc, ParentProperty)
    end.

property_counter() ->
    case persistent_term:get('schema_properties', 'undefined') of
        'undefined' ->
            Ref = counters:new(1, ['write_concurrency']),
            persistent_term:put('schema_properties', Ref),
            Ref;
        Ref ->
            Ref
    end.

increment_property_counter() ->
    counters:add(property_counter(), 1, 1).

reset_property_counter() ->
    counters:put(property_counter(), 1, 0).

property_count() ->
    counters:get(property_counter(), 1).

from_properties(ParentProperty) ->
    fun(K, V, Acc) ->
            increment_property_counter(),
            accessor_from_properties(ParentProperty ++ [K], V, Acc)
    end.

%% we build patternProperties when properties exists
build_from_pattern(PatternProperties, _SchemaJObj, Acc, ParentProperty) ->
    %% case kz_json:get_json_value(<<"properties">>, SchemaJObj) of
    %%     undefined -> Acc;
    %%     _Value -> build_from_pattern(PatternProperties, Acc, ParentProperty)
    %% end.
    build_from_pattern(PatternProperties, Acc, ParentProperty).

build_from_pattern(PatternProperties, Acc, ParentProperty) ->
    %% {Accessors, _} = kz_json:foldl(from_pattern_fun(ParentProperty), {Acc, []}, PatternProperties),
    {Accessors, _} = kz_json:foldl(fun accessor_from_pattern/3, {Acc, ParentProperty}, PatternProperties),
    Accessors.

%% from_pattern_fun(ParentProperty) ->
%%     fun(K, V, {Acc, Path}) ->
%%             accessor_from_pattern(K, V, {Acc, Path ++ ParentProperty})
%%     end.

save_module(Id, FileContents) ->
    SrcDir = code:lib_dir('kazoo_documents', 'src'),
    Filename = filename:join([SrcDir, <<"kzd_", (clean_name(Id))/binary, ".erl.src">>]),
    'ok' = file:write_file(Filename, FileContents).

accessor_from_pattern(<<"^_", _/binary>>, _Properties, Acc) -> Acc;
accessor_from_pattern(<<"^_pvt", _/binary>>, _Properties, Acc) -> Acc;
accessor_from_pattern(_Pattern, Properties, {Acc, Path}) ->
    PatternPath = pattern_path(Path, Properties),
    Acc1 = accessor_from_pattern(PatternPath, key_from_path(PatternPath), Properties, Acc),
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

accessor_from_pattern(Path, Key, Properties, {Exports, Accessors}) ->
    AccessorName = clean_name(Path),
    {add_pattern_exports(AccessorName, Key, Exports)
    ,add_pattern_accessors(AccessorName, Key, Properties, Accessors)
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
    case re:replace(Parent, <<"ies$">>, <<"y">>, [{'return', 'binary'}]) of
        Parent ->
            case kz_binary:strip_right(Parent, <<"s">>) of
                Parent -> kz_binary:join([Parent, <<"index">>], <<"_">>);
                Singular -> Singular
            end;
        Singular -> Singular
    end.

accessor_from_properties(Property, Schema, {Exports, Accessors}) ->
    Acc = {add_exports(clean_name(Property), Exports)
          ,add_accessors(clean_name(Property), Schema, Accessors)
          },
    maybe_add_sub_properties(Property, Schema, Acc, kz_json:get_value(<<"type">>, Schema)).

maybe_add_sub_properties(Property, Schema, Acc0, <<"object">>) ->
    case kz_json:is_true(<<"kz:skip_subproperty_builder">>, Schema) of
        'true' -> Acc0;
        'false' -> build_schema_accessors(Schema, Acc0, Property)
    end;
maybe_add_sub_properties(_Property, _Schema, Acc, _Type) ->
    Acc.

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

add_accessors(Property, Schema, Accessors) ->
    {JSONGetterFun, ReturnType} = json_getter_fun(Schema),
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

add_pattern_accessors(ParentProperty, Key, Schema, Accessors) ->
    {JSONGetterFun, ReturnType} = json_getter_fun(Schema),
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

json_getter_fun(Schema) ->
    json_getter_fun(Schema, kz_json:get_value(<<"type">>, Schema)).

json_getter_fun(_Schema, <<"object">>) ->
    {"get_json_value", "kz_json:object()"};
json_getter_fun(_Schema, <<"boolean">>) ->
    {"get_boolean_value", "boolean()"};
json_getter_fun(Schema, <<"array">>) ->
    {"get_list_value", list_return_subtype(Schema)};
json_getter_fun(_Schema, <<"integer">>) ->
    {"get_integer_value", "integer()"};
json_getter_fun(_Schema, <<"number">>) ->
    {"get_float_value", "number()"};
json_getter_fun(Schema, 'undefined') ->
    case kz_json:get_value(<<"$ref">>, Schema) of
        'undefined' ->
            case kz_json:get_list_value(<<"oneOf">>, Schema) of
                'undefined' ->
                    {"get_value", "any()"};
                OneOf ->
                    Types = [oneof(Type) || Type <- OneOf],
                    json_getter_fun(Schema, lists:usort(Types))
            end;
        Ref ->
            RefSchema = json_ref_schema(Schema, Ref),
            json_getter_fun(RefSchema, kz_json:get_value(<<"type">>, RefSchema))
    end;
json_getter_fun(Schema, <<"string">>) ->
    case kz_json:get_integer_value(<<"minLength">>, Schema) of
        N when is_integer(N), N > 0 ->
            {"get_ne_binary_value", "kz_term:ne_binary()"};
        _ ->
            {"get_binary_value", "binary()"}
    end;
json_getter_fun(_Schema, [{<<"array">>, <<"string">>}, <<"string">>]=_Type) ->
    {"get_ne_binary_or_binaries", "kz_term:ne_binary_or_binaries()"};
json_getter_fun(_Schema, [_|_]=_Type) ->
    {"get_value", "any()"}; %% composite type
json_getter_fun(_Schema, _Type) ->
    {"get_value", "any()"}.

json_ref_schema(_Schema, <<"#/", Key/binary>>) ->
    SchemaJObj = erlang:get('topschema'),
    Keys = binary:split(Key, <<"/">>, ['global']),
    kz_json:get_json_value(Keys, SchemaJObj);
json_ref_schema(_Schema, Ref) ->
    {'ok', RefSchema} = kz_json_schema:fload(Ref),
    RefSchema.

oneof(OneOf) ->
    case kz_json:get_value(<<"type">>, OneOf) of
        <<"array">> -> {<<"array">>, kz_json:get_value([<<"items">>, <<"type">>], OneOf)};
        Type -> Type
    end.

list_return_subtype(Schema) ->
    list_return_subtype(Schema, kz_json:get_value([<<"items">>, <<"type">>], Schema)).

list_return_subtype(Schema, 'undefined') ->
    case kz_json:get_value([<<"items">>, <<"$ref">>], Schema) of
        'undefined' -> "list()";
        Ref ->
            RefSchema = json_ref_schema(Schema, Ref),
            list_return_subtype(RefSchema, kz_json:get_value(<<"type">>, RefSchema))
    end;
list_return_subtype(_Schema, <<"string">>) -> "kz_term:ne_binaries()";
list_return_subtype(_Schema, <<"integer">>) -> "kz_term:integers()";
list_return_subtype(_Schema, <<"number">>) -> "[number()]";
list_return_subtype(_Schema, <<"object">>) -> "kz_json:objects()";
list_return_subtype(_Schema, _Type) ->
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
default_value_str("is_true", Default) ->
    ["'", kz_term:to_binary(Default), "'"];
default_value_str("is_false", Default) ->
    ["'", kz_term:to_binary(Default), "'"];
default_value_str("get_boolean_value", Default) ->
    ["'", kz_term:to_binary(Default), "'"];

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
    binary:replace(Name, [<<".">>, <<"-">>], <<"_">>, ['global']).

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

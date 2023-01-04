%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2017-2023, 2600Hz
%%% @doc Kazoo API Definition Helpers.
%%% @author Hesaam Farhang
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kapi_protobufs).

-export([generate_protobufs/0]).
-export([process_module/1]).

-include_lib("kazoo_stdlib/include/kz_log.hrl").

-spec generate_protobufs() -> 'ok'.
generate_protobufs() ->
    ?LOG_DEBUG("processing kapi protobufs: "),
    Options = [{'module', fun process_module/2}
              ,{'accumulator', 'ok'}
              ],
    _ = kazoo_ast:walk_project(Options),
    ?LOG_DEBUG(" done~n", []).

%% @doc pass in the kapi_definition to generate the .proto file
-spec process_module(module()) -> 'ok'.
process_module(Module) ->
    process_module(Module, 'ok').

process_module(Module, _) ->
    maybe_process_module(Module, kz_module:is_exported(Module, 'api_definitions', 0)).

maybe_process_module(_Module, 'false') -> {'skip', 'ok'};
maybe_process_module(Module, 'true') ->
    maybe_process_schemas(Module, application:get_application(Module)).

maybe_process_schemas(Module, {'ok', App}) ->
    <<"kapi_", KAPI/binary>> = kz_term:to_binary(Module),

    SchemaPaths = filename:join([code:priv_dir(App), "couchdb", "schemas", <<"kapi.", KAPI/binary, ".*">>]),
    ?LOG_DEBUG("checking ~s for schemas~n", [SchemaPaths]),
    maybe_process_schemas(Module, App, filelib:wildcard(kz_term:to_list(SchemaPaths)));
maybe_process_schemas(_Module, _E) -> {'skip', 'ok'}.

maybe_process_schemas(_Module, _App, []) -> {'skip', 'ok'};
maybe_process_schemas(Module, App, SchemaPaths) ->
    ProtoFilename = filename:join([code:priv_dir(App), "proto", [kz_term:to_list(Module), ".proto"]]),
    'ok' = kz_os:make_dir(ProtoFilename, 'true'),

    {'ok', IODevice} = file:open(ProtoFilename, ['write']),

    lists:foreach(fun(SchemaPath) -> process_schema(IODevice, SchemaPath) end
                 ,SchemaPaths
                 ),
    'ok' = file:close(IODevice),

    ?LOG_DEBUG("wrote ~s~n", [ProtoFilename]),
    ?LOG_DEBUG(".").

process_schema(IODevice, SchemaPath) ->
    ?LOG_DEBUG("opening ~s~n", [filename:basename(SchemaPath)]),
    {'ok', SchemaJObj} = kz_json_schema:fload(SchemaPath),

    generate_proto(IODevice, SchemaJObj).

generate_proto(IODevice, SchemaJObj) ->
    Properties = kz_json:get_json_value(<<"properties">>, SchemaJObj),
    generate_proto(IODevice, SchemaJObj
                  ,kz_json:get_ne_binary_value([<<"Event-Category">>, <<"enum">>, 1], Properties)
                  ,kz_json:get_ne_binary_value([<<"Event-Name">>, <<"enum">>, 1], Properties)
                  ).

generate_proto(_IODevice, _SchemaJObj, 'undefined', 'undefined') ->
    ?LOG_DEBUG("skipping~n");
generate_proto(IODevice, SchemaJObj, Category, Name) ->
    MessageName = message_name(Category, Name),
    write_message_name(IODevice, MessageName),

    MessageFields = generate_api_fields(SchemaJObj),
    'ok' = file:write(IODevice, MessageFields),

    'ok' = file:write(IODevice, <<"}\n\n">>).

write_message_name(IODevice, MessageName) ->
    'ok' = file:write(IODevice, ["message ", MessageName, " {\n"]).

generate_api_fields(Schema) ->
    {_S, _, _, MessageFields} =
        kz_json:foldl(fun generate_api_field/3
                     ,{Schema, 1, 16, []}
                     ,kz_json:get_json_value(<<"properties">>, Schema)
                     ),
    lists:reverse(MessageFields).

generate_api_field(FieldName, FieldSchema, {Schema, ReqIndex, OptIndex, MessageFields}) ->
    case lists:member(FieldName, kz_json:get_list_value(<<"required">>, Schema, [])) of
        'true' ->
            Field = generate_required_field(FieldName, FieldSchema, ReqIndex),
            {Schema, ReqIndex+1, OptIndex, [Field | MessageFields]};
        'false' ->
            Field = generate_optional_field(FieldName, FieldSchema, OptIndex),
            {Schema, ReqIndex, OptIndex+1, [Field | MessageFields]}
    end.

generate_required_field(FieldName, FieldSchema, Index) ->
    build_field(FieldName, FieldSchema, Index, <<"required">>).

generate_optional_field(FieldName, FieldSchema, Index) ->
    build_field(FieldName, FieldSchema, Index, <<"optional">>).

build_field(FieldName, FieldSchema, Index, InclusionType) ->
    build_field(FieldName, FieldSchema, Index, InclusionType
               ,kz_json:get_ne_binary_value(<<"type">>, FieldSchema)
               ).

build_field(FieldName, FieldSchema, Index, InclusionType, 'undefined') ->
    lager:warning("unset 'type' for field ~s, assuming string", [FieldName]),
    build_string_field(FieldName, FieldSchema, Index, InclusionType);
build_field(FieldName, FieldSchema, Index, InclusionType, <<"string">>) ->
    build_string_field(FieldName, FieldSchema, Index, InclusionType);
build_field(FieldName, _FieldSchema, Index, InclusionType, <<"integer">>) ->
    build_integer_field(FieldName, Index, InclusionType);
build_field(FieldName, FieldSchema, Index, InclusionType, <<"boolean">>) ->
    build_boolean_field(FieldName, FieldSchema, Index, InclusionType);
build_field(FieldName, FieldSchema, Index, InclusionType, <<"object">>) ->
    build_object_field(FieldName, FieldSchema, Index, InclusionType);
build_field(FieldName, FieldSchema, Index, _InclusionType, <<"array">>) ->
    build_array_field(FieldName, FieldSchema, Index, <<"repeated">>).

build_string_field(FieldName, FieldSchema, Index, InclusionType) ->
    build_string_field(FieldName, FieldSchema, Index, InclusionType
                      ,kz_json:get_list_value(<<"enum">>, FieldSchema, [])
                      ).

build_string_field(FieldName, _FieldSchema, Index, InclusionType, []) ->
    field_def(FieldName, Index, InclusionType, <<"string">>, 'undefined');
build_string_field(FieldName, _FieldSchema, Index, InclusionType, EnumValues) ->
    [enum_def(FieldName, EnumValues)
    ,field_def(FieldName, Index, InclusionType, enum_name(FieldName), default_enum(EnumValues))
    ].

default_enum([Default]) -> kz_term:to_upper_binary(Default);
default_enum(_) -> 'undefined'.

build_integer_field(FieldName, Index, InclusionType) ->
    field_def(FieldName, Index, InclusionType, <<"int32">>, 'undefined').

build_boolean_field(FieldName, FieldSchema, Index, InclusionType) ->
    field_def(FieldName, Index, InclusionType, <<"bool">>, kz_json:get_value(<<"default">>, FieldSchema)).

build_object_field(FieldName, FieldSchema, Index, InclusionType) ->
    build_object_field(FieldName, FieldSchema, Index, InclusionType
                      ,kz_json:get_json_value(<<"properties">>, FieldSchema)
                      ).

build_object_field(FieldName, _FieldSchema, Index, InclusionType, 'undefined') ->
    %% just a basic object
    field_def(FieldName, Index, InclusionType, map_type(<<"string">>, <<"string">>), 'undefined');
build_object_field(FieldName, FieldSchema, Index, InclusionType, _ObjectSchema) ->
    ObjectMessageFields = nested_message(FieldName, FieldSchema),
    [ObjectMessageFields
    ,field_def(FieldName, Index, InclusionType, field_name(FieldName), 'undefined')
    ].

nested_message(FieldName, ObjectSchema) ->
    MessageFields = generate_api_fields(ObjectSchema),
    ["  message ", field_name(FieldName), " {\n"
    ,MessageFields
    ,"  }\n"
    ].

build_array_field(FieldName, FieldSchema, Index, InclusionType) ->
    build_array_field(FieldName, FieldSchema, Index, InclusionType
                     ,kz_json:get_json_value(<<"items">>, FieldSchema)
                     ).

build_array_field(FieldName, _FieldSchema, Index, InclusionType, ItemSchema) ->
    FieldType = item_field_type(ItemSchema),
    field_def(FieldName, Index, InclusionType, FieldType, 'undefined').

item_field_type(ItemSchema) ->
    case kz_json:get_ne_binary_value(<<"type">>, ItemSchema, <<"string">>) of
        <<"string">> -> <<"string">>;
        <<"object">> -> build_object_subtype(ItemSchema)
    end.

build_object_subtype(ItemSchema) ->
    case kz_json:get_ne_binary_value(<<"$ref">>, ItemSchema) of
        'undefined' -> map_type(<<"string">>, <<"string">>);
        <<"kapi.", RefSchema/binary>> ->
            [Cat, Evt] = binary:split(RefSchema, <<".">>),
            message_name(Cat, Evt)
    end.

%% @doc emit map&lt;KeyType, ValueType%gt;
map_type(KeyType, ValueType) ->
    ["map<", KeyType, ", ", ValueType, ">"].

%% @doc fields are [InclusionType] [FieldType] [Field] = [Index] [default = Default];
field_def(FieldName, Index, InclusionType, FieldType, Default) ->
    ["  ", InclusionType, " ", FieldType, " "
    ,field_name(FieldName), " = ", integer_to_list(Index)
    ,default_value(Default)
    ,";\n"
    ].

default_value('undefined') -> "";
default_value([Default]) -> [" [default = ", kz_term:to_binary(Default), "]"];
default_value(V) -> [" [default = ", kz_term:to_binary(V), "]"].

%% @doc enum E[FieldName] { [ENUMVALUE] = Index;... }
enum_def(FieldName, EnumValues) ->
    {_, Enums} = lists:foldl(fun to_enum_string/2, {0, []}, EnumValues),
    ["  enum ", enum_name(FieldName), " {\n", Enums, "  }\n"].

enum_name(FieldName) ->
    ["E", field_name(FieldName)].

field_name(FieldName) ->
    binary:replace(FieldName, <<"-">>, <<>>, ['global']).

to_enum_string(Value, {Index, Acc}) ->
    {Index+1
    ,[["    ", kz_term:to_upper_binary(Value), " = ", integer_to_list(Index), ";\n"] | Acc]
    }.

message_name(<<Cat/binary>>, 'undefined') ->
    kz_binary:to_camel_case(Cat);
message_name(<<Cat/binary>>, <<Name/binary>>) ->
    [kz_binary:to_camel_case(Cat), kz_binary:to_camel_case(Name)].

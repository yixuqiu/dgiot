%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(dgiot_tdengine_schema).
-author("jonliu").
-include("dgiot_tdengine.hrl").
-include_lib("dgiot/include/logger.hrl").

-export([get_schema/2, create_database/1, create_table/2, alter_table/2]).

%% TDengine参数限制与保留关键字
%% https://www.taosdata.com/docs/cn/v2.0/administrator#keywords
get_schema(_ChannelId, Schema) ->
    case maps:get(<<"thing">>, Schema, <<>>) of
        <<>> ->
            ignore;
        Thing ->
            {Columns, Tags} = get_field_tag(Thing),
            case length(Columns) of
                0 ->
                    ignore;
                _ ->
                    #{<<"fields">> => Columns, <<"tags">> => Tags}
            end
    end.

get_field_tag(Thing) ->
    Properties = maps:get(<<"properties">>, Thing, []),
    Tags = maps:get(<<"tags">>, Thing, []),
    Columns =
        lists:foldl(fun(Property, Acc) ->
            case dgiot_tdengine_field:get_field(Property) of
                pass ->
                    Acc;
                V ->
                    Acc ++ [V]
            end
                    end, [], Properties),
    NewTags =
        lists:foldl(fun(Tag, Acc) ->
            case dgiot_tdengine_field:get_field(Tag) of
                pass ->
                    Acc;
                V ->
                    Acc ++ [V]
            end
                    end, [{<<"devaddr">>, #{<<"type">> => <<"NCHAR(50)">>}}], Tags),
    {lists:flatten(Columns), lists:flatten(NewTags)}.

create_database(Query) ->
    DataBase = maps:get(<<"db">>, Query),
    KeepTime = format_keep(Query),
    <<"CREATE DATABASE IF NOT EXISTS ", DataBase/binary, " KEEP ", KeepTime/binary>>.

format_keep(Query) ->
    Keep = maps:get(<<"keep">>, Query, 10),
    dgiot_utils:to_binary(Keep).


create_table(#{<<"tableName">> := TableName, <<"using">> := STbName, <<"tags">> := Tags} = _Query, _Context) ->
    TagFields = list_to_binary(dgiot_utils:join(",", Tags, fun dgiot_tdengine_select:format_value/1)),
    DB1 = dgiot_tdengine_select:format_db(TableName),
    <<"CREATE TABLE IF NOT EXISTS ", DB1/binary, TableName/binary, " USING ", STbName/binary, " TAGS (", TagFields/binary, ");">>;

create_table(#{<<"tableName">> := TableName, <<"fields">> := Fields0} = Query, Context) ->
    Database = dgiot_tdengine_select:format_db(TableName),
    alter_table(Query#{<<"db">> => Database}, Context),
    Fields =
        list_to_binary(dgiot_utils:join(",", ["createdat TIMESTAMP"] ++ lists:foldr(
            fun({FieldName, #{<<"type">> := Type}}, Acc) ->
                [<<FieldName/binary, " ", Type/binary>> | Acc]
            end, [], Fields0))),
    TagFields =
        list_to_binary(dgiot_utils:join(",", lists:foldr(
            fun({TagName, #{<<"type">> := TType}}, Acc) ->
                [<<TagName/binary, " ", TType/binary>> | Acc]
            end, [], maps:get(<<"tags">>, Query, [])))),
    case TagFields of
        <<>> ->
            <<"CREATE TABLE IF NOT EXISTS ", Database/binary, TableName/binary, " (", Fields/binary, ");">>;
        _ ->
            <<"CREATE TABLE IF NOT EXISTS ", Database/binary, TableName/binary, " (", Fields/binary, ") TAGS (", TagFields/binary, ");">>
    end.

alter_table(#{<<"db">> := Database, <<"tableName">> := TableName}, #{<<"channel">> := Channel} = Context) ->
    Sql1 = <<"DESCRIBE ", Database/binary, TableName/binary, ";">>,
    <<"_", ProductId/binary>> = TableName,
    Props = get_prop(ProductId),
    case dgiot_tdengine_pool:run_sql(Context, execute_query, Sql1) of
        {ok, #{<<"results">> := Results}} when length(Results) > 0 ->
            TdColumn =
                lists:foldl(fun(Column, Acc) ->
                    case Column of
                        #{<<"Field">> := Identifier, <<"Type">> := Type} ->
                            Acc#{Identifier => list_to_binary(string:to_lower(binary_to_list(Type)))};
                        _ ->
                            Acc
                    end
                            end, #{}, Results),
            <<"_", ProductId/binary>> = TableName,
            lists:foldl(fun(Prop, _Acc1) ->
                case Prop of
                    #{<<"dataType">> := #{<<"type">> := Type}, <<"identifier">> := Identifier, <<"isshow">> := true} ->
                        LowerIdentifier = list_to_binary(string:to_lower(binary_to_list(Identifier))),
                        case maps:find(LowerIdentifier, TdColumn) of
                            error ->
                                AddSql = dgiot_tdengine_field:add_field(Type, Database, TableName, LowerIdentifier),
                                dgiot_tdengine_pool:run_sql(Context#{<<"channel">> => Channel}, execute_query, AddSql);
                            _ ->
                                %% todo   类型改变
                                pass
                        end;
                    _ ->
                        pass
                end
                        end, #{}, Props),
            case dgiot_tdengine_pool:run_sql(Context#{<<"channel">> => Channel}, execute_query, Sql1) of
                {ok, #{<<"results">> := Results2}} ->
                    <<"_", ProductId/binary>> = TableName,
                    dgiot_data:insert({ProductId, ?TABLEDESCRIBE}, Results2);
                _ ->
                    pass
            end
    end.

get_prop(ProductId) ->
    case dgiot_data:get(dgiot_product, ProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
            lists:foldl(fun(X, Acc) ->
                case X of
                    #{<<"identifier">> := Identifier, <<"name">> := Name} ->
                        Acc#{Identifier => Name};
                    _ -> Acc
                end
                        end, #{}, Props);
        _ ->
            #{}
    end.
%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2014, 2600Hz INC
%%% @doc
%%% handler for route wins, bootstraps callflow execution
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(doodle_route_win).

-include("doodle.hrl").

-define(JSON(L), wh_json:from_list(L)).

-define(DEFAULT_SERVICES, ?JSON([{<<"audio">>, ?JSON([{<<"enabled">>, 'true'}])}
                           ,{<<"video">>,?JSON([{<<"enabled">>, 'true'}])}
                           ,{<<"sms">>,  ?JSON([{<<"enabled">>, 'true'}])}
                          ])).

-export([handle_req/2
         ,maybe_restrict_call/2
        ]).

-spec handle_req(wh_json:object(), wh_proplist()) -> any().
handle_req(JObj, _Options) ->
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    put('callid', CallId),
    lager:info("doodle has received a route win, taking control of the call"),
    case whapps_call:retrieve(CallId) of
        {'ok', Call} ->
            Call1 = whapps_call:from_route_win(JObj, Call),
            doodle_util:save_sms(JObj, Call1),
            maybe_restrict_call(JObj, Call1);
        {'error', R} ->
            lager:info("unable to find callflow during second lookup (HUH?) ~p", [R])
    end.

-spec maybe_restrict_call(wh_json:object(), whapps_call:call()) -> 'ok' | {'ok', pid()}.
maybe_restrict_call(JObj, Call) ->
    case should_restrict_call(Call) of
        'true' ->
            lager:debug("endpoint is restricted from making this call, terminate", []),
            'ok';
        'false' ->
            lager:info("setting initial information about the call"),
            bootstrap_callflow_executer(JObj, Call)
    end.

-spec should_restrict_call(whapps_call:call()) -> boolean().
should_restrict_call(Call) ->
    case cf_endpoint:get(Call) of
        {'error', _R} -> 'false';
        {'ok', JObj} -> maybe_service_unavailable(JObj, Call)
    end.

-spec maybe_service_unavailable(wh_json:object(), whapps_call:call()) -> boolean().
maybe_service_unavailable(JObj, Call) ->
    Id = wh_json:get_value(<<"_id">>, JObj),    
    Services = wh_json:merge_recursive(
                 wh_json:get_value(<<"services">>, JObj, ?DEFAULT_SERVICES),
                 wh_json:get_value(<<"pvt_services">>, JObj, wh_json:new())),
    case wh_json:is_true([<<"sms">>,<<"enabled">>], Services, 'true') of
        'true' ->
            maybe_account_service_unavailable(JObj, Call);
        'false' ->
            lager:debug("device ~s does not have sms service enabled", [Id]),
            'true'
    end.

-spec maybe_account_service_unavailable(wh_json:object(), whapps_call:call()) -> boolean().
maybe_account_service_unavailable(JObj, Call) ->
    AccountId = whapps_call:account_id(Call),
    AccountDb = whapps_call:account_db(Call),
    {'ok', Doc} = couch_mgr:open_cache_doc(AccountDb, AccountId),    
    Services = wh_json:merge_recursive(
                 wh_json:get_value(<<"services">>, Doc, ?DEFAULT_SERVICES),
                 wh_json:get_value(<<"pvt_services">>, Doc, wh_json:new())),
    case wh_json:is_true([<<"sms">>,<<"enabled">>], Services, 'true') of
        'true' ->
            maybe_closed_group_restriction(JObj, Call);
        'false' ->
            lager:debug("account ~s does not have sms service enabled", [AccountId]),
            'true'
    end.
  
-spec maybe_closed_group_restriction(wh_json:object(), whapps_call:call()) -> boolean().
maybe_closed_group_restriction(JObj, Call) ->
    case wh_json:get_value([<<"call_restriction">>, <<"closed_groups">>, <<"action">>], JObj) of
        <<"deny">> -> enforce_closed_groups(JObj, Call);
        _Else -> maybe_classification_restriction(JObj, Call)
    end.

-spec maybe_classification_restriction(wh_json:object(), whapps_call:call()) -> boolean().
maybe_classification_restriction(JObj, Call) ->
    Number = whapps_call:request_user(Call),
    Classification = wnm_util:classify_number(Number),
    lager:debug("classified number as ~s, testing for call restrictions", [Classification]),
    wh_json:get_value([<<"call_restriction">>, Classification, <<"action">>], JObj) =:= <<"deny">>.

-spec enforce_closed_groups(wh_json:object(), whapps_call:call()) -> boolean().
enforce_closed_groups(JObj, Call) ->
    case get_callee_extension_info(Call) of
        'undefined' ->
            lager:info("dialed number is not an extension, using classification restrictions", []),
            maybe_classification_restriction(JObj, Call);
        {<<"user">>, CalleeId} ->
            lager:info("dialed number is user ~s extension, checking groups", [CalleeId]),
            Groups = cf_attributes:groups(Call),
            CallerGroups = get_caller_groups(Groups, JObj, Call),
            CalleeGroups = get_group_associations(CalleeId, Groups),
            sets:size(sets:intersection(CallerGroups, CalleeGroups)) =:= 0;
        {<<"device">>, CalleeId} ->
            lager:info("dialed number is device ~s extension, checking groups", [CalleeId]),
            Groups = cf_attributes:groups(Call),
            CallerGroups = get_caller_groups(Groups, JObj, Call),
            maybe_device_groups_intersect(CalleeId, CallerGroups, Groups, Call)
    end.

-spec get_caller_groups(wh_json:objects(), wh_json:object(), whapps_call:call()) -> set().
get_caller_groups(Groups, JObj, Call) ->
    Ids = [whapps_call:authorizing_id(Call)
           ,wh_json:get_value(<<"owner_id">>, JObj)
           | wh_json:get_keys([<<"hotdesk">>, <<"users">>], JObj)
          ],
    lists:foldl(fun('undefined', Set) -> Set;
                   (Id, Set) ->
                        get_group_associations(Id, Groups, Set)
                end, sets:new(), Ids).

-spec maybe_device_groups_intersect(ne_binary(), set(), wh_json:objects(), whapps_call:call()) -> boolean().
maybe_device_groups_intersect(CalleeId, CallerGroups, Groups, Call) ->
    CalleeGroups = get_group_associations(CalleeId, Groups),
    case sets:size(sets:intersection(CallerGroups, CalleeGroups)) =:= 0 of
        'false' -> 'false';
        'true' ->
            %% In this case the callee-id is a device id, find out if
            %% the owner of the device shares any groups with the caller
            UserIds = cf_attributes:owner_ids(CalleeId, Call),
            UsersGroups = lists:foldl(fun(UserId, Set) ->
                                             get_group_associations(UserId, Groups, Set)
                                     end, sets:new(), UserIds),
            sets:size(sets:intersection(CallerGroups, UsersGroups)) =:= 0
    end.

-spec get_group_associations(ne_binary(), wh_json:objects()) -> set().
get_group_associations(Id, Groups) ->
    get_group_associations(Id, Groups, sets:new()).

-spec get_group_associations(ne_binary(), wh_json:objects(), set()) -> set().
get_group_associations(Id, Groups, Set) ->
    lists:foldl(fun(Group, S) ->
                        case wh_json:get_value([<<"value">>, Id], Group) of
                            'undefined' -> S;
                            _Else ->
                                GroupId = wh_json:get_value(<<"id">>, Group),
                                sets:add_element(GroupId, S)
                        end
                end, Set, Groups).

-spec get_callee_extension_info(whapps_call:call()) -> {ne_binary(), ne_binary()} | 'undefined'.
get_callee_extension_info(Call) ->
    Flow = whapps_call:kvs_fetch('cf_flow', Call),
    FirstModule = wh_json:get_value(<<"module">>, Flow),
    FirstId = wh_json:get_value([<<"data">>, <<"id">>], Flow),
    SecondModule = wh_json:get_value([<<"_">>, <<"module">>], Flow),
    case (FirstModule =:= <<"device">> orelse FirstModule =:= <<"user">>)
        andalso
        (SecondModule =:= <<"voicemail">> orelse SecondModule =:= 'undefined')
        andalso
        FirstId =/= 'undefined'
    of
        'true' -> {FirstModule, FirstId};
        'false' -> 'undefined'
    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%-----------------------------------------------------------------------------
-spec bootstrap_callflow_executer(wh_json:object(), whapps_call:call()) -> {'ok', pid()}.
bootstrap_callflow_executer(_JObj, Call) ->
    Routines = [fun store_owner_id/1
                ,fun update_ccvs/1
                %% all funs above here return whapps_call:call()
                ,fun execute_callflow/1
               ],
    lists:foldl(fun(F, C) -> F(C) end, Call, Routines).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%-----------------------------------------------------------------------------
-spec store_owner_id(whapps_call:call()) -> whapps_call:call().
store_owner_id(Call) ->
    OwnerId = cf_attributes:owner_id(Call),
    whapps_call:kvs_store('owner_id', OwnerId, Call).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%-----------------------------------------------------------------------------
-spec update_ccvs(whapps_call:call()) -> whapps_call:call().
update_ccvs(Call) ->
    CallerIdType = case whapps_call:inception(Call) of
                       'undefined' -> <<"internal">>;
                       _Else -> <<"external">>
                   end,
    {CIDNumber, CIDName} = cf_attributes:caller_id(CallerIdType, Call),
    lager:info("bootstrapping with caller id type ~s: \"~s\" ~s"
               ,[CallerIdType, CIDName, CIDNumber]),
    Props = props:filter_undefined(
              [{<<"Hold-Media">>, cf_attributes:moh_attributes(<<"media_id">>, Call)}
               ,{<<"Caller-ID-Name">>, CIDName}
               ,{<<"Caller-ID-Number">>, CIDNumber}
               | get_incoming_security(Call)
              ]),
    whapps_call:set_custom_channel_vars(Props, Call).

-spec get_incoming_security(whapps_call:call()) -> wh_proplist().
 get_incoming_security(Call) ->
    case cf_endpoint:get(Call) of
        {'error', _R} -> [];
        {'ok', JObj} ->
            wh_json:to_proplist(
              cf_util:encryption_method_map(wh_json:new(), JObj)
            )
    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% executes the found call flow by starting a new doodle_exe process under the
%% doodle_exe_sup tree.
%% @end
%%-----------------------------------------------------------------------------
-spec execute_callflow(whapps_call:call()) -> {'ok', pid()}.
execute_callflow(Call) ->
    lager:info("message has been setup, beginning to process the message"),
    doodle_exe_sup:new(Call).

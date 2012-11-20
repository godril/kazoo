%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(acdc_queue_handler).

-export([handle_call_event/2
         ,handle_member_call/3
         ,handle_member_resp/2
         ,handle_member_accepted/2
         ,handle_member_retry/2
         ,handle_config_change/2
         ,handle_stats_req/2
         ,handle_presence_probe/2
        ]).

-include("acdc.hrl").

handle_call_event(JObj, Props) ->
    true = wapi_call:event_v(JObj),
    {Cat, Name} = wh_util:get_event_type(JObj),
    acdc_queue_fsm:call_event(props:get_value(fsm_pid, Props), Cat, Name, JObj).

handle_member_call(JObj, Props, Delivery) ->
    true = wapi_acdc_queue:member_call_v(JObj),
    lager:debug("member call ~s being sent to FSM ~p"
                ,[wh_json:get_value(<<"Call-ID">>, JObj)
                  ,props:get_value(fsm_pid, Props)
                 ]),
    acdc_queue_fsm:member_call(props:get_value(fsm_pid, Props), JObj, Delivery).

handle_member_resp(JObj, Props) ->
    true = wapi_acdc_queue:member_connect_resp_v(JObj),
    acdc_queue_fsm:member_connect_resp(props:get_value(fsm_pid, Props), JObj).

handle_member_accepted(JObj, Props) ->
    true = wapi_acdc_queue:member_connect_accepted_v(JObj),
    acdc_queue_fsm:member_accepted(props:get_value(fsm_pid, Props), JObj).

handle_member_retry(JObj, Props) ->
    true = wapi_acdc_queue:member_connect_retry_v(JObj),
    acdc_queue_fsm:member_connect_retry(props:get_value(fsm_pid, Props), JObj).

handle_config_change(JObj, _Props) ->
    true = wapi_conf:doc_update_v(JObj),
    handle_queue_change(wh_json:get_value(<<"Doc">>, JObj)
                        ,wh_json:get_value(<<"pvt_account_id">>, JObj)
                        ,wh_json:get_value(<<"_id">>, JObj)
                        ,wh_json:get_value(<<"Event-Name">>, JObj)
                       ).

handle_queue_change(_JObj, AcctId, QueueId, <<"doc_created">>) ->
    case acdc_queues_sup:find_queue_supervisor(AcctId, QueueId) of
        undefined -> acdc_queues_sup:new(AcctId, QueueId);
        P when is_pid(P) -> ok
    end;
handle_queue_change(JObj, AcctId, QueueId, <<"doc_edited">>) ->
    case acdc_queues_sup:find_queue_supervisor(AcctId, QueueId) of
        undefined -> acdc_queues_sup:new(AcctId, QueueId);
        QueueSup when is_pid(QueueSup) ->
            WorkersSup = acdc_queue_sup:workers_sup(QueueSup),
            [acdc_queue_fsm:refresh(acdc_queue_worker_sup:fsm(WorkerSup), JObj)
             || WorkerSup <- acdc_queue_workers_sup:workers(WorkersSup)
            ]
    end;
handle_queue_change(_JObj, AcctId, QueueId, <<"doc_deleted">>) ->
    case acdc_queues_sup:find_queue_supervisor(AcctId, QueueId) of
        undefined -> lager:debug("no queue(~s) started for account ~s", [QueueId, AcctId]);
        P when is_pid(P) ->
            lager:debug("stopping queue(~s) in account ~s (deleted): ~p", [QueueId, AcctId, P]),
            acdc_queue_sup:stop(P)
    end.

handle_stats_req(JObj, _Props) ->
    true = wapi_acdc_queue:stats_req_v(JObj),
    handle_stats_req(wh_json:get_value(<<"Account-ID">>, JObj)
                     ,wh_json:get_value(<<"Queue-ID">>, JObj)
                     ,wh_json:get_value(<<"Server-ID">>, JObj)
                     ,wh_json:get_value(<<"Msg-ID">>, JObj)
                    ).

handle_stats_req(AcctId, undefined, ServerId, MsgId) ->
    build_stats_resp(AcctId, ServerId, MsgId, acdc_queues_sup:find_acct_supervisors(AcctId));
handle_stats_req(AcctId, QueueId, ServerId, MsgId) ->
    case acdc_queues_sup:find_queue_supervisor(AcctId, QueueId) of
        undefined -> lager:debug("queue ~s in acct ~s isn't running", [QueueId, AcctId]);
        P when is_pid(P) -> build_stats_resp(AcctId, ServerId, MsgId, [P])
    end.

-spec build_stats_resp/4 :: (api_binary(), api_binary(), api_binary(), [pid()] | []) -> any().
-spec build_stats_resp/5 :: (api_binary(), api_binary(), api_binary(), [pid()] | []
                             ,wh_json:json_object()
                            ) -> any().
build_stats_resp(AcctId, RespQ, MsgId, Ps) ->
    build_stats_resp(AcctId, RespQ, MsgId, Ps
                     ,wh_json:new()
                    ).

build_stats_resp(AcctId, RespQ, MsgId, [], CurrCalls) ->
    Resp = props:filter_undefined(
             [{<<"Account-ID">>, AcctId}
              ,{<<"Current-Calls">>, CurrCalls}
              ,{<<"Current-Stats">>, acdc_stats:queue_stats(AcctId)}
              ,{<<"Msg-ID">>, MsgId}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    wapi_acdc_queue:publish_stats_resp(RespQ, Resp);
build_stats_resp(AcctId, RespQ, MsgId, [P|Ps], CurrCalls) ->
    MgrPid = acdc_queue_sup:manager(P),
    {AcctId, QueueId} = acdc_queue_manager:config(MgrPid),

    CurrentCalls = [{ACallId, ACallData}
                    || {ACallId, ACallData} <- wh_json:to_proplist(acdc_stats:current_calls(AcctId, QueueId)),
                       ACallId =/= undefined,
                       ACallData =/= undefined
                   ],

    QueueCalls = wh_json:get_value(QueueId, CurrCalls, wh_json:new()),

    build_stats_resp(AcctId, RespQ, MsgId, Ps
                     ,wh_json:set_value(QueueId, wh_json:set_values(CurrentCalls, QueueCalls), CurrCalls)
                    ).

handle_presence_probe(JObj, _Props) ->
    true = wapi_notifications:presence_probe_v(JObj),

    FromRealm = wh_json:get_value(<<"From-Realm">>, JObj),
    {ok, AcctDb} = whapps_util:get_account_by_realm(FromRealm),

    maybe_respond_to_presence_probe(JObj, AcctDb).

maybe_respond_to_presence_probe(JObj, AcctDb) ->
    case wh_json:get_value(<<"To-User">>, JObj) of
        undefined ->
            lager:debug("no to-user found on json: ~p", [JObj]);
        QueueId ->
            {ok, Doc} = couch_mgr:open_doc(AcctDb, QueueId),

            AcctId = wh_util:format_account_id(AcctDb, raw),
            lager:debug("looking for probe for queue ~s(~s)", [QueueId, AcctId]),

            maybe_update_probe(JObj, AcctId, QueueId, wh_json:get_value(<<"pvt_type">>, Doc))
    end.

maybe_update_probe(JObj, AcctId, QueueId, <<"queue">>) ->
    update_probe(JObj, wapi_acdc_queue:queue_size(AcctId, QueueId));
maybe_update_probe(_, _, _, _) ->
    ok.

update_probe(JObj, 0) ->
    lager:debug("no calls in queue, greenify!"),
    send_probe(JObj, ?PRESENCE_GREEN);
update_probe(JObj, N) when is_integer(N), N > 0 ->
    lager:debug("~b calls in queue, redify!", [N]),
    send_probe(JObj, ?PRESENCE_RED_FLASH);
update_probe(_JObj, _Size) ->
    lager:debug("~p for queue size, ignore!", [_Size]).

send_probe(JObj, State) ->
    To = wh_json:get_value(<<"To">>, JObj),

    PresenceUpdate =
        [{<<"State">>, State}
         ,{<<"Presence-ID">>, To}
         ,{<<"Call-ID">>, wh_util:to_hex_binary(crypto:md5(To))}
         ,{<<"Switch-Nodename">>, wh_json:get_ne_value(<<"Switch-Nodename">>, JObj)}
         ,{<<"Subscription-Call-ID">>, wh_json:get_ne_value(<<"Subscription-Call-ID">>, JObj)}
         | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
        ],
    wapi_notifications:publish_presence_update(PresenceUpdate).

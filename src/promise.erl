-module(promise).


-include_lib("eunit/include/eunit.hrl").


-export([
         valid_handle/1,
         make/1,
         make/2,
         chain_list/1,
         cancel/1,
         await/1,
         await/2,
         get_state/1,
         get_state/2
        ]).

-record(handle, {pid, ref}).
-record(state, {s, pubref, privref,childpid,error,value}).

valid_handle(#handle{pid=P}) ->
    is_process_alive(P).

make(Func) ->
    make(Func, unit).
make(Func, Arg) when is_function(Func) ->
    F = case erlang:fun_info(Func, arity) of
            {arity, 0} -> fun(_) -> Func() end; % lambda wrap
            {arity, 1} -> Func
        end,
    PrivRef = make_ref(),
    PubRef = make_ref(),
    Outer = fun() ->
                    process_flag(trap_exit, true),
                    OuterPid = self(),
                    Inner = fun() ->
                                    Result = F(Arg),
                                    OuterPid ! {self(), PrivRef, Result}
                            end,
                    Child = spawn_link(Inner),
                    promise_loop(#state{s=pending,pubref=PubRef,privref=PrivRef,
                                        childpid=Child,value=none})
            end,
    Pid = spawn(Outer),
    #handle{pid=Pid,ref=PubRef}.

await(Handle) ->
    await(Handle, infinity).
await(Handle=#handle{pid=Pid,ref=Ref}, Timeout) ->
    case valid_handle(Handle) of
        false ->
            {error, invalid_handle};
        true ->
            Pid ! {await, Ref, self(), Timeout},
            receive
                {ok, Result} -> {ok, Result};
                {error, X} -> {error, X};
                timeout -> {error, timeout}
            end
    end.

cancel(Handle) ->
    cancel(Handle, infinity).
cancel(Handle = #handle{pid=Pid,ref=Ref}, Timeout) ->
    case valid_handle(Handle) of
        false -> {error, invalid_handle};
        true ->
            Pid ! {cancel, Ref, self(), Timeout},
            receive
                {Pid, ok, cancelled} -> {ok, cancelled};
                {Pid, error, timeout} -> {ok, timeout}
            end
    end.

get_state(Handle) ->
    get_state(Handle, infinity).
get_state(#handle{pid=Pid,ref=Ref}, Timeout) ->
    Pid ! {getstate, Ref, self()},
    receive {Pid, Ref, {state, S}} ->
            {ok, S}
    after Timeout -> {error, timeout}
    end.

%% Foldable :)
chain_list([]) ->
    {error, empty};
chain_list([H|[]]) ->
    make(H);
chain_list([H|R]) ->
    I = make(H),
    lists:foldl(fun(F, Acc) -> chain2(Acc, F) end, I, R).

%% Private
chain2(Handle, F) ->
    F2 = fun() -> {ok, R} = await(Handle), F(R) end,
    make(F2).

%% Value not received
promise_loop(State = #state{s=pending,pubref=PubRef,privref=PrivRef,
                            childpid=ChildPid,value=none,error=Error}) ->
    receive
        {ChildPid, PrivRef, Result} ->
            promise_loop(State#state{s=complete,error=false,value=Result});
        {'EXIT',ChildPid,Error} ->
            promise_loop(State#state{s=complete,error=true,value=Error});
        {cancel, PubRef, From, Timeout} ->
            exit(ChildPid, kill),
            receive {'EXIT', ChildPid, killed} ->
                    From ! {self(), ok, cancelled},
                    promise_loop(State#state{s=complete,
                                             error=false,value=cancelled})
            after Timeout ->
                    From ! {self(), error, timeout},
                    promise_loop(State)
            end;
        {getstate, PubRef, From} ->
            From ! {self(), PubRef, {state, State#state.s}};
        {await, PubRef, From, Timeout} ->
            receive
                {ChildPid, PrivRef, Result} -> From ! {ok, Result};
                {'EXIT',ChildPid,Error} -> From ! {error, Error}
            after Timeout ->
                    From ! timeout,
                    promise_loop(State)
            end
    end;
%% received value, no error (includes cancellation)
promise_loop(State = #state{s=complete,pubref=PubRef,privref=_PrivRef,
                             childpid=_ChildPid,error=false,value=Value}) ->
    receive
        {await, PubRef, From, _Timeout} -> From ! {ok, Value};
        {getstate, PubRef, From} ->
            From ! {self(), PubRef, {state, State#state.s}},
            promise_loop(State)
    end;
%% received value, error
promise_loop(State = #state{s=complete,pubref=PubRef,privref=_PrivRef,
                             childpid=_ChildPid,error=true,value=Value}) ->
    receive {await, PubRef, From, _Timeout} -> From ! {error, Value};
        {getstate, PubRef, From} ->
            From ! {self(), PubRef, {state, State#state.s}},
            promise_loop(State)
    end.

%% EUNIT
-ifdef(EUNIT).

promise_basic_test() ->
    F = fun() -> 10 end,
    H = make(F),
    ?assertEqual(await(H), {ok, 10}).

promise_delay_test() ->
    %% Sleep for 100ms then return value
    F = fun() -> timer:sleep(100), 10 end,
    H = make(F),
    ?assertEqual(await(H), {ok, 10}).

promise_multiple_test() ->
    %% 2 promises
    H1 = make(fun() -> timer:sleep(100), 10 end),
    H2 = make(fun() -> 10 end),
    F = fun() ->
            {ok, Y} = await(H2),
            {ok, X} = await(H1),
            X * Y
    end,
    ?assertEqual(F(), 100).

promise_chain2_test() ->
    %% compose 2 promises
    H1 = make(fun() -> 10 end),
    H2 = chain2(H1, fun(X) -> X * 10 end),
    ?assertEqual({ok, 100}, await(H2)).

promise_chain_list_test() ->
    %% compose N promises
    F1 = fun() -> 1 end,
    F2 = fun(X) -> X * 2 end,
    H = chain_list([F1, F2, F2, F2]), %% 2 ^3
    ?assertEqual({ok, 8}, await(H)).

promise_cancel_test() ->
    %% messy test. try to guarantee that the side effect (sending a message)
    %% did not occur after cancellation

    %% listening - wait to receive a message, and send it back
    R = spawn(fun() -> receive {From, X} -> From ! X end end),
    %% send R a message after 100ms
    P = make(fun() -> timer:sleep(50), R ! {self(), promise} end),
    %% cancel P
    {ok, cancelled} = cancel(P),
    {ok, cancelled} = await(P),
    %% R should still be waiting
    ?assert(is_process_alive(R)),
    %% Just check that it make sure we implemented the R and P correctly
    R ! {self(), main},
    receive main -> ?assertNot(is_process_alive(R))
    after 100 -> error("Expected R to respond")
    end.

promise_get_state_test() ->
    S = self(),
    H = make(fun() -> S ! {self(), req}, receive {S, ack} -> done  end, ?debugMsg("finishing promise") end),
    {ok, pending} = get_state(H),
    ?debugMsg("Got state"),
    receive {P, req} ->
            P ! {S, ack}
    after 1000 ->
        exit(did_not_receive_message)
    end,
    {ok, completed} = get_state(H),
    {ok, done} = await(H).

-endif.

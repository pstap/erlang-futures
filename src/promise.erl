-module(promise).

-export([
         valid_handle/1,
         make/1,
         make/2,
         chain_list/1,
         cancel/1,
         await/1,
         await/2
        ]).

-record(handle, {pid, ref}).
-record(state, {pubref, privref,childpid,error,value}).

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
                    promise_loop(#state{pubref=PubRef,privref=PrivRef,childpid=Child,value=none})
            end,
    Pid = spawn(Outer),
    #handle{pid=Pid,ref=PubRef}.

await(Handle) ->
    await(Handle, infinity).
await(_Handle=#handle{pid=Pid,ref=Ref}, Timeout) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! {await, Ref, self(), Timeout},
            receive
                {ok, Result} -> {ok, Result};
                {error, X} -> {error, X};
                timeout -> {error, timeout}
            end;
        false ->
            {error, invalid_handle}
    end.

cancel(Handle = #handle{pid=Pid,ref=Ref}) ->
    case valid_handle(Handle) of
        false -> {error, invalid_handle};
        true ->  Pid ! {cancel, Ref, self()}
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
promise_loop(State = #state{pubref=PubRef,privref=PrivRef,
                            childpid=ChildPid,value=none,error=Error}) ->
    receive
        {ChildPid, PrivRef, Result} -> promise_loop(State#state{error=false,value=Result});
        {'EXIT',ChildPid,Error} -> promise_loop(State#state{error=true,value=Error});
        {cancel, PubRef, _From} -> exit(ChildPid, kill), promise_loop(State#state{error=false,value=cancelled});
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
promise_loop(_State = #state{pubref=PubRef,privref=_PrivRef,
                             childpid=_ChildPid,error=false,value=Value}) ->
    receive {await, PubRef, From, _Timeout} ->
            From ! {ok, Value}
    end;
%% received value, error
promise_loop(_State = #state{pubref=PubRef,privref=_PrivRef,
                             childpid=_ChildPid,error=true,value=Value}) ->
    receive {await, PubRef, From, _Timeout} ->
            From ! {error, Value}
    end.

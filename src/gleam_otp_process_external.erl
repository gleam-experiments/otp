-module(gleam_otp_process_external).

% Public functions
-export([send_exit/2, sync_send/3, receive_system_message_forever/0]).

-include("gen/src/gleam@otp@process_From.hrl").
-include("gen/src/gleam@otp@process_Message.hrl").
-include("gen/src/gleam@otp@process_System.hrl").

-define(is_record(Tag, Arity, Term),
        (is_tuple(Term)
         andalso tuple_size(Term) =:= Arity + 1
         andalso element(1, Term) =:= Tag)).

-define(is_system_msg(Term), ?is_record(system, 2, Term)).
-define(is_monitor_msg(Term), ?is_record('DOWN', 4, Term)).
-define(is_exit_msg(Term), ?is_record('EXIT', 2, Term)).
-define(is_gleam_special_msg(Term), ?is_record('$gleam_special', 1, Term)).

-define(is_special_msg(Term),
        (?is_system_msg(Term)
         orelse ?is_monitor_msg(Term)
         orelse ?is_exit_msg(Term)
         orelse ?is_gleam_special_msg(Term))).

-define(exit_msg_constructor_key, '$gleam_exit_msg_constructor').

send_exit(Pid, Reason) ->
  exit(Pid, Reason),
  nil.

receive_system_message_forever() ->
  receive
    {system, From, Request} -> normalise_system_msg(From, Request)
  end.

%do_receive(Timeout) ->
%  receive
%    {system, From, Request} ->
%      #system{message = normalise_system_msg(From, Request)};
%
%    % TODO
%    % {'EXIT', Pid, Reason} ->
%    %   #exit{pid = Pid, reason = Reason};
%
%    % TODO
%    % {'DOWN', Ref, process, Pid, Reason} ->
%    %   #process_down{ref = Ref, pid = Pid, reason = Reason};
%
%    % TODO
%    % {'DOWN', Ref, port, Port, Reason} ->
%    %   #port_down{ref = Ref, port = Port, reason = Reason};
%
%    Msg when ?is_gleam_special_msg(Msg) ->
%      unexpected_msg(Msg);
%
%    Msg ->
%      #message{message = Msg}
%  after
%    Timeout -> {error, nil}
%  end.

%unexpected_msg(Msg) ->
%  % TODO: make Msg into a binary
%  exit({abnormal, {gleam_unexpected_message, Msg}}).

normalise_system_msg(From, Msg) when Msg =:= get_state orelse Msg =:= get_status ->
  {Msg, gen_from_to_gleam_from(From)};
normalise_system_msg(From, Msg) when Msg =:= suspend orelse Msg =:= resume ->
  {Msg, gen_from_to_gleam_ok_from(From)}.

% This function is implemented in Erlang as it requires selective receives.
% It is based off of gen:do_call/4.
sync_send(Process, MakeMsg, Timeout) ->
  {RequestRef, Replier} = new_from(Process),
  erlang:send(Process, MakeMsg(Replier), [noconnect]),
  receive
    {RequestRef, Reply} ->
      erlang:demonitor(RequestRef, [flush]),
      Reply;

    {'DOWN', RequestRef, _, _, noconnection} ->
      Node = node(Process),
      exit({nodedown, Node});

    {'DOWN', RequestRef, _, _, Reason} ->
      exit(Reason)
  after
    Timeout ->
      erlang:demonitor(RequestRef, [flush]),
      exit(timeout)
  end.

new_from(Process) ->
  RequestRef = erlang:monitor(process, Process),
  From = gen_from_to_gleam_from({self(), RequestRef}),
  {RequestRef, From}.

gen_from_to_gleam_ok_from(GenFrom) ->
  From = gen_from_to_gleam_from(GenFrom),
  Reply = fun(_) -> (From#from.reply)(ok) end,
  From#from{reply = Reply}.

gen_from_to_gleam_from({Pid, RequestRef}) ->
  Reply = fun(Reply) ->
    Msg = {RequestRef, Reply},
    catch erlang:send(Pid, Msg),
    nil
  end,
  #from{reply = Reply}.

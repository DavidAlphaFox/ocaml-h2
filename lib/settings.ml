(*----------------------------------------------------------------------------
 *  Copyright (c) 2019 António Nuno Monteiro
 *
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *  this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *  notice, this list of conditions and the following disclaimer in the
 *  documentation and/or other materials provided with the distribution.
 *
 *  3. Neither the name of the copyright holder nor the names of its
 *  contributors may be used to endorse or promote products derived from this
 *  software without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 *  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 *  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 *  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 *  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 *  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 *  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 *  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 *  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *---------------------------------------------------------------------------*)

module WindowSize = struct
  type t = int

  (* From RFC7540§6.9.2:
   *   When an HTTP/2 connection is first established, new streams are created
   *   with an initial flow-control window size of 65,535 octets. *)
  let default_initial_window_size = 65535

  (* From RFC7540§6.9:
   *   The legal range for the increment to the flow-control window is 1 to
   *   2^31-1 (2,147,483,647) octets. *)
  let max_window_size = (1 lsl 31) - 1

  (* Ideally `n` here would be an unsigned 32-bit integer, but OCaml doesn't
   * support them. We avoid introducing a new dependency on an unsigned integer
   * library by letting it overflow at parse time and checking if bit 31 is set
   * here, since * `Window.max_window_size` is never allowed to be above
   * 2^31-1 (see `max_window_size` above).
   * See http://caml.inria.fr/pub/ml-archives/caml-list/2004/07/f1c483068cc62075c916f7ad7d640ce0.fr.html
   * for more info. *)
  let is_window_overflow n = Util.test_bit n 31
end

type key =
  | HeaderTableSize
  | EnablePush
  | MaxConcurrentStreams
  | InitialWindowSize
  | MaxFrameSize (* this means payload size *)
  | MaxHeaderListSize

type value = int

type settings_list = (key * value) list

(* From RFC7540§6.5.1:
 *   The payload of a SETTINGS frame consists of zero or more parameters,
 *   each consisting of an unsigned 16-bit setting identifier and an
 *   unsigned 32-bit value. *)
let octets_per_setting = 6

let serialize_key = function
  | HeaderTableSize ->
    0x1
  | EnablePush ->
    0x2
  | MaxConcurrentStreams ->
    0x3
  | InitialWindowSize ->
    0x4
  | MaxFrameSize ->
    0x5
  | MaxHeaderListSize ->
    0x6

let parse_key = function
  | 0x1 ->
    Some HeaderTableSize
  | 0x2 ->
    Some EnablePush
  | 0x3 ->
    Some MaxConcurrentStreams
  | 0x4 ->
    Some InitialWindowSize
  | 0x5 ->
    Some MaxFrameSize
  | 0x6 ->
    Some MaxHeaderListSize
  | _ ->
    None

let check_value ~is_client = function
  | EnablePush, v ->
    if v != 0 && v != 1 then
      (* From RFC7540§6.5.2
       *   The initial value is 1, which indicates that server push is
       *   permitted. Any value other than 0 or 1 MUST be treated as a
       *   connection error (Section 5.4.1) of type PROTOCOL_ERROR. *)
      Error
        Error.(
          ConnectionError (ProtocolError, "SETTINGS_ENABLE_PUSH must be 0 or 1"))
    else if is_client && v == 1 then
      (* From RFC7540§8.2:
       *   Clients MUST reject any attempt to change the
       *   SETTINGS_ENABLE_PUSH setting to a value other than 0 by
       *   treating the message as a connection error (Section 5.4.1) of
       *   type PROTOCOL_ERROR. *)
      Error
        Error.(
          ConnectionError
            (ProtocolError, "Server must not try to enable SETTINGS_ENABLE_PUSH"))
    else
      Ok ()
  | InitialWindowSize, v when WindowSize.is_window_overflow v ->
    (* From RFC7540§6.5.2
     *   Values above the maximum flow-control window size of 2^31-1 MUST be
     *   treated as a connection error (Section 5.4.1) of type
     *   FLOW_CONTROL_ERROR. *)
    Error
      Error.(
        ConnectionError
          ( FlowControlError
          , Format.sprintf
              "Window size must be less than or equal to %d"
              WindowSize.max_window_size ))
  | MaxFrameSize, v when v < 16384 || v > 16777215 ->
    (* From RFC7540§6.5.2
     *   The initial value is 214 (16,384) octets. The value advertised by an
     *   endpoint MUST be between this initial value and the maximum allowed
     *   frame size (224-1 or 16,777,215 octets), inclusive. Values outside
     *   this range MUST be treated as a connection error (Section 5.4.1) of
     *   type PROTOCOL_ERROR. *)
    Error
      Error.(
        ConnectionError
          (ProtocolError, "Max frame size must be in the 16384 - 16777215 range"))
  | _ ->
    Ok ()

(* Check incoming settings and report an error if any. *)
let check_settings_list ?(is_client = false) settings =
  let rec loop = function
    | [] ->
      Ok ()
    | x :: xs ->
      (match check_value ~is_client x with
      | Ok () ->
        loop xs
      | Error _ as err ->
        err)
  in
  loop settings

type t =
  { mutable header_table_size : int
  ; mutable enable_push : bool
  ; mutable max_concurrent_streams : int
  ; mutable initial_window_size : int
  ; mutable max_frame_size : int
  ; mutable max_header_list_size : int option
  }

(* From RFC7540§11.3 *)
let default_settings =
  { header_table_size = 0x1000
  ; enable_push =
      true
      (* From RFC7540§6.5.2:
       *   SETTINGS_MAX_CONCURRENT_STREAMS (0x3): [...] Initially, there is no
       *   limit to this value. *)
  ; max_concurrent_streams = Int32.(to_int max_int)
  ; initial_window_size = WindowSize.default_initial_window_size
  ; max_frame_size = 0x4000
  ; max_header_list_size = None
  }

let settings_for_the_connection settings =
  let settings_list =
    if settings.max_frame_size <> default_settings.max_frame_size then
      [ MaxFrameSize, settings.max_frame_size ]
    else
      []
  in
  let settings_list =
    if
      settings.max_concurrent_streams <> default_settings.max_concurrent_streams
    then
      (MaxConcurrentStreams, settings.max_concurrent_streams) :: settings_list
    else
      settings_list
  in
  let settings_list =
    if settings.initial_window_size <> default_settings.initial_window_size then
      (InitialWindowSize, settings.initial_window_size) :: settings_list
    else
      settings_list
  in
  let settings_list =
    if settings.enable_push <> default_settings.enable_push then
      (EnablePush, if settings.enable_push then 1 else 0) :: settings_list
    else
      settings_list
  in
  settings_list

let parse_settings_payload num_settings =
  let open Angstrom in
  let parse_setting =
    lift2
      (fun k v ->
        match parse_key k with
        | Some s ->
          Some (s, Int32.to_int v)
        | None ->
          None)
      BE.any_uint16
      BE.any_int32
  in
  (* Note: This ignores unknown settings.
   *
   * From RFC7540§6.5.3:
   *   Unsupported parameters MUST be ignored.
   *)
  lift
    (fun xs ->
      let rec filter_opt acc = function
        | [] ->
          acc []
        | Some x :: xs ->
          filter_opt (fun ys -> acc (x :: ys)) xs
        | None :: xs ->
          filter_opt acc xs
      in
      (* From RFC7540§6.5.3:
       *   The values in the SETTINGS frame MUST be processed in the order
       *   they appear, with no other frame processing between values. *)
      filter_opt (fun x -> x) xs)
    (count num_settings parse_setting)

let rec write_settings_payload t settings_list =
  let open Faraday in
  match settings_list with
  | [] ->
    ()
  | (key, value) :: xs ->
    (* From RFC7540§6.5.1:
     *   The payload of a SETTINGS frame consists of zero or more parameters,
     *   each consisting of an unsigned 16-bit setting identifier and an
     *   unsigned 32-bit value. *)
    BE.write_uint16 t (serialize_key key);
    BE.write_uint32 t (Int32.of_int value);
    write_settings_payload t xs

let of_base64 encoded =
  match Base64.decode ~alphabet:Base64.uri_safe_alphabet encoded with
  | Ok settings_payload ->
    let settings_payload_length =
      String.length settings_payload / octets_per_setting
    in
    Angstrom.parse_string
      (parse_settings_payload settings_payload_length)
      settings_payload
  | Error (`Msg msg) ->
    Error msg

let to_base64 settings =
  let faraday = Faraday.create (List.length settings * 6) in
  write_settings_payload faraday settings;
  let settings_hex = Faraday.serialize_to_string faraday in
  match Base64.encode ~alphabet:Base64.uri_safe_alphabet settings_hex with
  | Ok r ->
    Ok r
  | Error (`Msg msg) ->
    Error msg

let pp_hum formatter t =
  let string_of_key = function
    | HeaderTableSize ->
      "HEADER_TABLE_SIZE"
    | EnablePush ->
      "ENABLE_PUSH"
    | MaxConcurrentStreams ->
      "MAX_CONCURRENT_STREAMS"
    | InitialWindowSize ->
      "INITIAL_WINDOW_SIZE"
    | MaxFrameSize ->
      "MAX_FRAME_SIZE"
    | MaxHeaderListSize ->
      "MAX_HEADER_LIST_SIZE"
  in
  let pp_elem formatter (key, value) =
    Format.fprintf formatter "@[(%S %d)@]" (string_of_key key) value
  in
  Format.fprintf formatter "@[(";
  Format.pp_print_list pp_elem formatter t;
  Format.fprintf formatter ")@]"

// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary show BIG_ENDIAN
import net.tcp
import reader
import writer

OPCODE_CONTINUATION_ ::= 0
OPCODE_TEXT_         ::= 1
OPCODE_BINARY_       ::= 2
OPCODE_CLOSE_        ::= 8
OPCODE_PING_         ::= 9
OPCODE_PONG_         ::= 10
FIN_FLAG_            ::= 0x80
EIGHT_BYTE_SIZE_     ::= 127
TWO_BYTE_SIZE_       ::= 126
MAX_ONE_BYTE_SIZE_   ::= 125

/**
A WebSocket connection.
A bidirectional socket connection capable of sending binary or text messages
  according to RFC 6455.
Obtained from the $Client.web_socket method.
Currently the server side setup is not implemented.
Currently does not implement ping and pong packets.
*/
class WebSocket:
  socket_ /tcp.Socket
  pending_ /ByteArray? := null
  current_writer_ /WebSocketWriter? := null
  current_reader_ /WebSocketReader? := null

  constructor .socket_:

  read_ -> ByteArray?:
    if pending_:
      result := pending_
      pending_ = null
      return result
    return socket_.read

  unread_ byte_array/ByteArray -> none:
    assert: pending_ == null
    pending_ = byte_array

  /**
  Returns a reader for the next message sent to us on the WebSocket.
  Returns null if the connection is closed.
  Should not be called until the previous reader has been fully read.
  */
  receive -> WebSocketReader?:
    if current_reader_ != null: throw "PREVIOUS_READER_NOT_FINISHED"
    fragment_reader := receive_
    if fragment_reader == null: return null
    if fragment_reader.is_ping or fragment_reader.is_pong:
      throw "UNIMPLEMENTED_PING"
    if fragment_reader.is_close:
      return null
    if fragment_reader.is_continuation:
      throw "PROTOCOL_ERROR"
    size := fragment_reader.size_
    current_reader_ = WebSocketReader.private_ this fragment_reader fragment_reader.is_text fragment_reader.size
    return current_reader_

  // Reads the header of the next fragment.
  receive_ -> FragmentReader_?:
    // Named block:
    get_more := :
      next := socket_.read
      if next == null:
        if pending_ == null: return null
        throw "CONNECTION_CLOSED"
      pending_ = pending_ ? pending_ + next : next

    while pending_ == null or pending_.size < 2: get_more.call

    masking := pending_[1] & 0x80 != 0
    len := pending_[1] & 0x7f
    header_size_needed := ?
    if len == TWO_BYTE_SIZE_:
      header_size_needed = masking ? 8 : 4
    else if len == EIGHT_BYTE_SIZE_:
      header_size_needed = masking ? 14 : 10
    else:
      header_size_needed = masking ? 6 : 2

    while pending_.size < header_size_needed: get_more.call

    if len == TWO_BYTE_SIZE_:
      len = BIG_ENDIAN.uint16 pending_ 2
    else if len == EIGHT_BYTE_SIZE_:
      len = BIG_ENDIAN.int64 pending_ 2

    masking_bytes := masking
        ? pending_.copy (header_size_needed - 4) header_size_needed
        : null
    result := FragmentReader_ this len pending_[0] --masking_bytes=masking_bytes
    if not result.is_ok_: throw "PROTOCOL_ERROR"
    pending_ = pending_[header_size_needed..]
    return result

  /**
  Sends a ByteArray or string as a framed WebSockets message.
  Strings are sent as text, whereas byte arrays are sent as binary.
  */
  send data -> none:
    writer := send --size=data.size
    writer.write data
    writer.close

  /**
  Starts sending a message to the peer.
  If the size is given, the message is sent as a single fragment so that
    the receiver knows the size.  In theory, proxies could split the fragment
    into multiple fragments, which would ruin this.  In practice this seems
    rare, and with TLS it is almost impossible.
  The fragment size is at the WebSockets level and has no connection with
    the size of IP packets or TLS buffers.
  The message is sent as a text message if the first data written to the
    writer is a string, otherwise as a binary message.
  Returns a writer, which must be completed (all data sent, and closed) before
    this method can be called again.
  */
  send --size/int?=null -> WebSocketWriter:
    if current_writer_: throw "PREVIOUS_WRITER_NOT_CLOSED"
    current_writer_ = WebSocketWriter.private_ this size
    return current_writer_

  writer_close_ writer/WebSocketWriter -> none:
    if current_writer_ != writer: throw "WRONG_WRITER_CALLED_CLOSE"
    current_writer_ = null

  write_ data -> none:
    written := 0
    while written < data.size:
      written += socket_.write data[written..]

  reader_close_ -> none:
    current_reader_ = null

  /**
  Abruptly closes the WebSocket.
  Does not send a close packet first.
  */
  close:
    socket_.close
    current_writer_ = null

/**
A writer for writing a single message on a WebSocket connection.
*/
class WebSocketWriter:
  owner_ /WebSocket? := ?
  size_ /int?
  remaining_in_fragment_ /int := 0
  fragment_sent_ /bool := false

  constructor.private_ .owner_ .size_:

  write data -> int:
    if owner_ == null: throw "ALREADY_CLOSED"
    from := 0
    while true:
      while from < data.size and remaining_in_fragment_ != 0:
        size := min data.size - from remaining_in_fragment_
        owner_.write_ data[from..from + size]
        from += size
      remaining_in_fragment_ -= data.size
      if from == data.size: return data.size

      opcode := data is string ? OPCODE_TEXT_ : OPCODE_BINARY_
      if fragment_sent_:
        opcode = OPCODE_CONTINUATION_
      else:
        fragment_sent_ = true

      header := ?
      if size_:
        // We know the size.  Write a single fragment with the fin flag and the
        // exact size.
        if opcode == OPCODE_CONTINUATION_: throw "TOO_MUCH_WRITTEN"
        remaining_in_fragment_ = size_
        if size_ > 0xffff:
          header = ByteArray 10
          header[1] = EIGHT_BYTE_SIZE_
          BIG_ENDIAN.put_int64 header 2 size_
        else if size_ > MAX_ONE_BYTE_SIZE_:
          header = ByteArray 4
          header[1] = TWO_BYTE_SIZE_
          BIG_ENDIAN.put_uint16 header 2 size_
        else:
          header = ByteArray 2
          header[1] = size_
        header[0] = opcode | FIN_FLAG_
      else:
        // We don't know the size.  Write multiple fragments of up to
        // 126 bytes.
        remaining_in_fragment_ = min MAX_ONE_BYTE_SIZE_ data.size - from
        header = ByteArray 2
        header[0] = opcode
        header[1] = remaining_in_fragment_
      owner_.write_ header

  close:
    if remaining_in_fragment_ != 0: throw "TOO_LITTLE_WRITTEN"
    if owner_:
      if size_ == null:
        header := ByteArray 2
        header[0] = FIN_FLAG_ | (fragment_sent_ ? OPCODE_CONTINUATION_ : OPCODE_BINARY_)
        owner_.write_ header
      owner_.writer_close_ this
      owner_ = null

/**
A reader for an individual message sent to us.
*/
class WebSocketReader implements reader.Reader:
  owner_ /WebSocket? := ?
  is_text /bool
  fragment_reader_ /FragmentReader_ := ?

  /**
  If the size of the incoming message is known, then it is returned, otherwise
    null is returned.
  Since a normal size method cannot return null, the WebSocketReader does not
    implement $reader.SizedReader.
  */
  size /int?

  constructor.private_ .owner_ .fragment_reader_ .is_text .size:

  /**
  Returns a byte array, or null if the message has been fully read.
  Note that even if the message is transmitted as text, it arrives as
    ByteArrays.
  */
  read -> ByteArray?:
    result := fragment_reader_.read
    if result == null:
      if fragment_reader_.is_fin:
        if owner_:
          owner_.reader_close_
          owner_ = null
          return null
      if owner_ == null: return null  // Closed.
      fragment_reader_ = owner_.receive_
      if fragment_reader_.is_ping or fragment_reader_.is_pong:
        throw "UNIMPLEMENTED_PING"
      else if not fragment_reader_.is_continuation:
        throw "PROTOCOL_ERROR"
      result = fragment_reader_.read
    if fragment_reader_.is_fin and fragment_reader_.is_exhausted:
      if owner_:
        owner_.reader_close_
        owner_ = null
    return result

class FragmentReader_:
  owner_ /WebSocket
  control_bits_ /int
  size_ /int ::= ?
  received_ := 0
  masking_bytes /ByteArray? := null

  constructor .owner_ .size_ .control_bits_ --masking_bytes/ByteArray?=null:

  is_continuation -> bool: return control_bits_ & 0x0f == OPCODE_CONTINUATION_
  is_text -> bool:         return control_bits_ & 0x0f == OPCODE_TEXT_
  is_binary -> bool:       return control_bits_ & 0x0f == OPCODE_BINARY_
  is_close -> bool:        return control_bits_ & 0x0f == OPCODE_CLOSE_
  is_ping -> bool:         return control_bits_ & 0x0f == OPCODE_PING_
  is_pong -> bool:         return control_bits_ & 0x0f == OPCODE_PONG_
  is_fin -> bool:          return control_bits_ & FIN_FLAG_ != 0
  is_exhausted -> bool:    return received_ == size_

  is_ok_ -> bool:
    if control_bits_ & 0x70 != 0: return false
    opcode := control_bits_ & 0xf
    return opcode < 3 or 8 <= opcode <= 10

  read -> ByteArray?:
    if received_ == size_:
      return null
    next_byte_array := owner_.read_
    if next_byte_array == null: throw "CONNECTION_CLOSED"
    max := size_ - received_
    if next_byte_array.size > max:
      owner_.unread_ next_byte_array[max..]
      next_byte_array = next_byte_array[..max]
    if masking_bytes:
      // TODO: Use blit for this.
      masking_bytes.size.do:
        next_byte_array[it] ^= masking_bytes[received_++ & 3]
    else:
      received_ += next_byte_array.size
    return next_byte_array

  size -> int?:
    if control_bits_ & FIN_FLAG_ == 0:
      return null
    return size_

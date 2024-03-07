// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import encoding.url
import reader
import writer

import .headers
import .chunked
import .response
import .connection

/**
Legacy interface for older code.
*/
abstract class Request:
  abstract method -> string
  abstract path -> string
  abstract headers -> Headers
  abstract body -> reader.Reader?
  body= value/reader.Reader: throw "NOT_IMPLEMENTED"
  send -> Response: throw "NOT_IMPLEMENTED"
  content_length -> int?: throw "NOT_IMPLEMENTED"
  abstract drain -> none

/// Outgoing request to an HTTP server, we are acting like a client.
class RequestOutgoing extends Request:
  connection_/Connection := ?

  method/string
  path/string
  headers/Headers

  /**
  The body of the outgoing request.
  Assign to this to give the outgoing request a body to write something to the
    server.
  This is especially useful for POST requests, which often contain
    uploaded data.  The body should be set before calling the $send
    method.
  */
  body/reader.Reader? := null

  constructor.private_ .connection_ .method .path .headers:

  send -> Response:
    has_body := body != null
    content_length := has_body and (body is reader.SizedReader)
        ? (body as reader.SizedReader).size
        : null
    slash := (path.starts_with "/") ? "" : "/"
    body_writer := connection_.send_headers
        "$method $slash$path HTTP/1.1\r\n"
        headers
        --is_client_request=true
        --content_length=content_length
        --has_body=has_body
    if body:
      while data := body.read:
        body_writer.write data
    body_writer.close
    return connection_.read_response

  drain:
    if body: while body.read:

/// Incoming request from an HTTP client like a browser, we are the server.
class RequestIncoming extends Request:
  connection_/Connection := ?

  /// The HTTP method, usually "GET" or "POST".
  method/string
  /// The full path of the request, eg. "/page?id=123".
  path/string
  /// The parsed version of the path.  For routing purposes use query.resource.
  query/url.QueryString
  headers/Headers
  /// The HTTP version.
  version/string

  /**
  Read from this to get any data from the client, eg from a POST
    request.
  */
  body/reader.Reader

  constructor.private_ .connection_ .body .method .path .version .headers:
    query = url.QueryString.parse path

  content_length -> int?:
    if body is ContentLengthReader:
      return (body as ContentLengthReader).content_length
    return null

  drain:
    while body.read:

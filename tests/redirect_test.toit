// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import http
import net
import encoding.json

HOST ::= "httpbin.org"
PATH_GET ::= "/absolute-redirect/3"
PATH_POST ::= "/redirect-to?url=http%3A%2F%2Fhttpbin.org%2F%2Fpost&status_code=302"
PATH_POST303 ::= "/redirect-to?url=http%3A%2F%2Fhttpbin.org%2F%2Fget&status_code=303"

drain response/http.Response:
  while response.body.read: null

check_get_response response/http.Response --scheme:
  data := #[]
  while chunk := response.body.read:
    data += chunk
  expect_equals 200 response.status_code
  decoded := json.decode data
  expect_equals "$scheme://httpbin.org/get" decoded["url"]

test_get network/net.Interface:
  client := http.Client network

  response := client.get HOST PATH_GET
  check_get_response response --scheme="http"

  response = client.get HOST PATH_GET --no-follow_redirect
  expect_equals 302 response.status_code
  drain response

test_post network/net.Interface:
  client := http.Client network

  response := client.post --host=HOST --path=PATH_POST #['h', 'e', 'l', 'l', 'o']
  data := #[]
  while chunk := response.body.read:
    data += chunk
  expect_equals 200 response.status_code
  decoded := json.decode data
  expect_equals "hello" decoded["data"]

  response = client.post --host=HOST --path=PATH_POST #['h', 'e', 'l', 'l', 'o'] --no-follow_redirect
  expect_equals 302 response.status_code
  drain response

  // A post to a redirect 303 should become a GET.
  response = client.post --host=HOST --path=PATH_POST303 #['h', 'e', 'l', 'l', 'o']
  data = #[]
  while chunk := response.body.read:
    data += chunk
  expect_equals 200 response.status_code
  decoded = json.decode data
  expect decoded["args"].is_empty

  response = client.post --host=HOST --path=PATH_POST303 #['h', 'e', 'l', 'l', 'o'] --no-follow_redirect
  expect_equals 303 response.status_code
  drain response


main:
  network := net.open

  test_get network
  test_post network

  network.close


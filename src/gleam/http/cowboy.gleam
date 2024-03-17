import gleam/list
import gleam/pair
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/http.{type Header}
import gleam/http/service.{type Service}
import gleam/http/request.{Request}
import gleam/bytes_builder.{type BytesBuilder}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/http/cookie

type CowboyRequest

@external(erlang, "gleam_cowboy_native", "start_link")
fn erlang_start_link(
  handler: fn(CowboyRequest) -> CowboyRequest,
  port: Int,
) -> Result(Pid, Dynamic)

@external(erlang, "cowboy_req", "reply")
fn cowboy_reply(
  status: Int,
  headers: Dict(String, Dynamic),
  body: BytesBuilder,
  request: CowboyRequest,
) -> CowboyRequest

@external(erlang, "cowboy_req", "set_resp_cookie")
fn erlang_set_resp_cookie(name: String, value: String, request: CowboyRequest, opts: Dict(String, String) ) -> CowboyRequest

fn set_resp_cookie(cookie_header: #(String, String), request: CowboyRequest) -> CowboyRequest {
  let cookie_info = cookie.parse(cookie_header.1)
  let result = list.pop(cookie_info, fn(_){True})
  case result {
   Ok(#(#(name, value), opts)) -> erlang_set_resp_cookie(name, value, request, 
      opts
      |> dict.from_list
    )
    _ -> request
  }
}

@external(erlang, "cowboy_req", "method")
fn erlang_get_method(request: CowboyRequest) -> Dynamic

fn get_method(request) -> http.Method {
  request
  |> erlang_get_method
  |> http.method_from_dynamic
  |> result.unwrap(http.Get)
}

@external(erlang, "cowboy_req", "headers")
fn erlang_get_headers(request: CowboyRequest) -> Dict(String, String)

fn get_headers(request) -> List(http.Header) {
  request
  |> erlang_get_headers
  |> dict.to_list
}

@external(erlang, "gleam_cowboy_native", "read_entire_body")
fn get_body(request: CowboyRequest) -> #(BitArray, CowboyRequest)

@external(erlang, "cowboy_req", "scheme")
fn erlang_get_scheme(request: CowboyRequest) -> String

fn get_scheme(request) -> http.Scheme {
  request
  |> erlang_get_scheme
  |> http.scheme_from_string
  |> result.unwrap(http.Http)
}

@external(erlang, "cowboy_req", "qs")
fn erlang_get_query(request: CowboyRequest) -> String

fn get_query(request) -> Option(String) {
  case erlang_get_query(request) {
    "" -> None
    query -> Some(query)
  }
}

@external(erlang, "cowboy_req", "path")
fn get_path(request: CowboyRequest) -> String

@external(erlang, "cowboy_req", "host")
fn get_host(request: CowboyRequest) -> String

@external(erlang, "cowboy_req", "port")
fn get_port(request: CowboyRequest) -> Int

fn cowboy_format_headers(headers: List(Header)) -> Dict(String, Dynamic) {
  headers
  |> list.map(pair.map_second(_, dynamic.from))
  |> dict.from_list
}

fn service_to_handler(
  service: Service(BitArray, BytesBuilder),
) -> fn(CowboyRequest) -> CowboyRequest {
  fn(request) {
    let #(body, request) = get_body(request)
    let response =
      service(Request(
        body: body,
        headers: get_headers(request),
        host: get_host(request),
        method: get_method(request),
        path: get_path(request),
        port: Some(get_port(request)),
        query: get_query(request),
        scheme: get_scheme(request),
      ))
    let status = response.status
    // We split the cookie headers from the rest of the headers
    // This is due to a change in cowboyh 2.11.0 which means cookie headers must
    // now be set using cowboy_req:set_resp_cookie
    let #(headers, cookie_headers) = list.partition(response.headers, fn(header) { 
      case header {
        #(k, _) -> k != "set-cookie"
      }
    })

    let headers = cowboy_format_headers(headers)
    let request = list.fold(cookie_headers, request, fn(req, c) {
      set_resp_cookie(c, req)
    })
    let body = response.body
    cowboy_reply(status, headers, body, request)
  }
}

// TODO: document
// TODO: test
pub fn start(
  service: Service(BitArray, BytesBuilder),
  on_port number: Int,
) -> Result(Pid, Dynamic) {
  service
  |> service_to_handler
  |> erlang_start_link(number)
}

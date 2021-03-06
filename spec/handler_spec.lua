local config = require('config')
local handler = require('handler')
local http = require('resty.http')
local util = require('util')
local target = require('target')
local Dict = require("spec/support/fake_shared_dict")
local fake_ngx = require("spec/support/fake_ngx")

local stub_fn, unstub_fn = _G.stub_fn, _G.unstub_fn

describe("handler", function()
  local cache, fngx

  setup(function()
    cache = Dict:new()
    handler.cache = cache

    fngx = fake_ngx.new()
    handler._ngx = fngx
  end)

  before_each(function()
    cache:flush_all()
    fngx.reset()
  end)

  describe(".handle", function()
    local resolve_stub, httpc_stub

    before_each(function()
      httpc_stub = {}
      stub(http, 'new', httpc_stub)
      httpc_stub.request_uri = function(self, uri, opts)
        assert(false,'should not be executed')
      end
    end)

    after_each(function()
      http.new:revert()
    end)

    context("when path has query string or # fragment", function()
      before_each(function()
        resolve_stub = stub_fn(target, "resolve", function(path, webroot, drop_dot_html)
          return "/", true, nil
        end)
      end)

      after_each(function()
        unstub_fn(target, "resolve")
      end)

      it("strips query string", function()
        local tgt, err, err_log = handler.handle("a1b2c3-123", "/?utm_code=123&ref=ph?abc=asd")

        assert.are.equal(tgt, "/")
        assert.are.equal(err, handler.err_redirect)
        assert.is_nil(err_log)

        assert.spy(resolve_stub).was_called_with("/", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

        assert.are.equal(cache:get("a1b2c3-123:/:tgt"), "/")
        assert.is_true(cache:get("a1b2c3-123:/:rdr"))
      end)

      it("strips # fragment", function()
        local tgt, err, err_log = handler.handle("a1b2c3-123", "/#app/here/there")

        assert.are.equal(tgt, "/")
        assert.are.equal(err, handler.err_redirect)
        assert.is_nil(err_log)

        assert.spy(resolve_stub).was_called_with("/", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

        assert.are.equal(cache:get("a1b2c3-123:/:tgt"), "/")
        assert.is_true(cache:get("a1b2c3-123:/:rdr"))
      end)
    end)

    context("when a redirection should happen", function()
      before_each(function()
        resolve_stub = stub_fn(target, "resolve", function(path, webroot, drop_dot_html)
          return "/foo", true, nil
        end)
      end)

      after_each(function()
        unstub_fn(target, "resolve")
      end)

      it("caches target resolution, returns new path and redirect error", function()
        local tgt, err, err_log = handler.handle("a1b2c3-123", "/foo.html")

        assert.are.equal(tgt, "/foo")
        assert.are.equal(err, handler.err_redirect)
        assert.is_nil(err_log)

        assert.spy(resolve_stub).was_called_with("/foo.html", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

        assert.are.equal(cache:get("a1b2c3-123:/foo.html:tgt"), "/foo")
        assert.is_true(cache:get("a1b2c3-123:/foo.html:rdr"))
      end)
    end)

    context("when target is found", function()
      before_each(function()
        resolve_stub = stub_fn(target, "resolve", function(path, webroot, drop_dot_html)
          return "/index.html", false, nil
        end)
      end)

      after_each(function()
        unstub_fn(target, "resolve")
      end)

      context("when the requested resource exists in s3", function()
        before_each(function()
          httpc_stub.request_uri = function(self, uri, opts)
            assert.are.equal(uri, "http://test-s3.example.com/deployments/a1b2c3-123/webroot/index.html")
            assert.are.same(opts, { method = "HEAD" })
            return {
              status = 200
            }, nil
          end
        end)

        it("cache target resolution, returns asset url and no error", function()
          local tgt, err, err_log = handler.handle("a1b2c3-123", "/")

          assert.are.equal(tgt, config.s3_host.."/deployments/a1b2c3-123/webroot/index.html")
          assert.is_nil(err)
          assert.is_nil(err_log)

          assert.spy(resolve_stub).was_called_with("/", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

          assert.are.equal(cache:get("a1b2c3-123:/:tgt"), "/index.html")
          assert.is_false(cache:get("a1b2c3-123:/:rdr"))
        end)
      end)

      context("the file does not exist on s3", function()
        local headers

        before_each(function()
          httpc_stub.request_uri = function(self, uri, opts)
            assert.are.equal(uri, "http://test-s3.example.com/deployments/a1b2c3-123/webroot/index.html")
            assert.are.same(opts, { method = "HEAD" })

            return {
              status = 403 -- s3 returns 403 access denied when an object does not exist
            }, nil
          end

          headers = {
            ["Content-Length"] = "23",
            ["Content-Type"] = "text/html",
            Date = "Thu, 07 Apr 2016 18:14:23 GMT",
            ETag = '"bf7f567450d007008332ac96d29032d3"',
            ["Last-Modified"] = "Tue, 29 Mar 2016 22:19:55 GMT",
            Server = "AmazonS3",
            ["x-amz-id-2"] = "8J2guyuubw0qfpLNYmu1d",
            ["x-amz-request-id"] = "5s8sQ96UeDGAk49kHbq93FlWAyeQxnrZSdAXCt"
          }
        end)

        context("when 200.html exists (push state support)", function()
          before_each(function()
            stub_fn(util, "request_uri_stream", function(httpc, uri, params, res_callback, data_callback)
              assert.are.equal(httpc, httpc_stub)
              -- when both 404.html and 200.html exist, prefer 200.html
              assert.are.equal(
                uri == "http://test-s3.example.com/deployments/a1b2c3-123/webroot/200.html" or
                uri == "http://test-s3.example.com/deployments/a1b2c3-123/webroot/404.html"
              , true)
              assert.are.same(params, {})
              res_callback({
                status = 200,
                headers = headers
              })
              if string.sub(uri, -9) == "/200.html" then
                data_callback("<h1>200")
                data_callback(" OK</h1>")
              end
              if string.sub(uri, -9) == "/404.html" then
                data_callback("<h1>404")
                data_callback(" Not Found</h1>")
              end
            end)
          end)

          after_each(function()
            unstub_fn(util, "request_uri_stream")
          end)

          it("returns /200.html page with status 200 ok", function()
            local tgt, err, err_log = handler.handle("a1b2c3-123", "/")

            assert.is_nil(tgt)
            assert.is_nil(err)
            assert.is_nil(err_log)

            assert.spy(resolve_stub).was_called_with("/", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

            assert.is_nil(cache:get("a1b2c3-123:/:tgt"))
            assert.is_nil(cache:get("a1b2c3-123:/:rdr"))

            assert.are.same(fngx.print_calls, { "<h1>200", " OK</h1>" })
            assert.are.equal(fngx.status, 200)
            assert.are.same(fngx.header, headers)
            assert.are.same(fngx.exit_calls, { 200 })
          end)
        end)

        context("when 404.html exists (custom 404 page)", function()
          before_each(function()
            stub_fn(util, "request_uri_stream", function(httpc, uri, params, res_callback, data_callback)
              assert.are.equal(
                uri == "http://test-s3.example.com/deployments/a1b2c3-123/webroot/200.html" or
                uri == "http://test-s3.example.com/deployments/a1b2c3-123/webroot/404.html"
              , true)
              assert.are.same(params, {})
              if string.sub(uri, -9) == "/200.html" then
                res_callback({
                  status = 404,
                  headers = headers
                })
              end
              if string.sub(uri, -9) == "/404.html" then
                res_callback({
                  status = 200,
                  headers = headers
                })
                data_callback("<h1>404")
                data_callback(" Not Found</h1>")
              end
            end)
          end)

          after_each(function()
            unstub_fn(util, "request_uri_stream")
          end)

          it("returns /404.html page with status 404 not found", function()
            local tgt, err, err_log = handler.handle("a1b2c3-123", "/")

            assert.is_nil(tgt)
            assert.is_nil(err)
            assert.is_nil(err_log)

            assert.spy(resolve_stub).was_called_with("/", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

            assert.is_nil(cache:get("a1b2c3-123:/:tgt"))
            assert.is_nil(cache:get("a1b2c3-123:/:rdr"))

            assert.are.same(fngx.print_calls, { "<h1>404", " Not Found</h1>" })
            assert.are.equal(fngx.status, 404)
            assert.are.same(fngx.header, headers)
            assert.are.same(fngx.exit_calls, { 404 })
          end)
        end)

        context("when neither 200.html nor 404.html exists", function()
          before_each(function()
            stub_fn(util, "request_uri_stream", function(httpc, uri, params, res_callback, data_callback)
              assert.are.equal(
                uri == "http://test-s3.example.com/deployments/a1b2c3-123/webroot/200.html" or
                uri == "http://test-s3.example.com/deployments/a1b2c3-123/webroot/404.html"
              , true)
              assert.are.same(params, {})

              res_callback({
                status = 404,
                headers = headers
              })
            end)
          end)

          after_each(function()
            unstub_fn(util, "request_uri_stream")
          end)

          it("returns status 403 forbidden", function()
            -- nginx should recognize this 403 response and serve default 404 page with status 404

            local tgt, err, err_log = handler.handle("a1b2c3-123", "/")

            assert.is_nil(tgt)
            assert.is_nil(err)
            assert.is_nil(err_log)

            assert.spy(resolve_stub).was_called_with("/", config.s3_host.."/deployments/a1b2c3-123/webroot", true)

            assert.is_nil(cache:get("a1b2c3-123:/:tgt"))
            assert.is_nil(cache:get("a1b2c3-123:/:rdr"))

            assert.are.same(fngx.print_calls, {})
            assert.are.same(fngx.exit_calls, { 403 })
          end)
        end)
      end)
    end)
  end)
end)

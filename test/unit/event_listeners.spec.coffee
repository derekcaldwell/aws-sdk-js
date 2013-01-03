# Copyright 2012-2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
#     http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

helpers = require('../helpers')
AWS = helpers.AWS
MockClient = helpers.MockClient

describe 'AWS.EventListeners', ->

  oldSetTimeout = setTimeout
  config = null; client = null; totalWaited = null; delays = []
  successHandler = null; errorHandler = null; completeHandler = null
  retryHandler = null

  beforeEach ->
    # Mock the timer manually (jasmine.Clock does not work in node)
    `setTimeout = jasmine.createSpy('setTimeout');`
    setTimeout.andCallFake (callback, delay) ->
      totalWaited += delay
      delays.push(delay)
      callback()

    totalWaited = 0
    delays = []
    client = new MockClient(maxRetries: 3)
    client.config.credentials = AWS.util.copy(client.config.credentials)

    # Helpful handlers
    successHandler = createSpy('success')
    errorHandler = createSpy('error')
    completeHandler = createSpy('complete')
    retryHandler = createSpy('retry')

  # Safely tear down setTimeout hack
  afterEach -> `setTimeout = oldSetTimeout`

  makeRequest = (callback) ->
    request = client.makeRequest('mockMethod', foo: 'bar')
    request.on('retry', retryHandler)
    request.on('error', errorHandler)
    request.on('success', successHandler)
    request.on('complete', completeHandler)
    if callback
      request.on 'complete', (resp) ->
        callback.call(resp, resp.error, resp.data)
      request.send()
    else
      request

  describe 'validate', ->
    it 'sends error event if credentials are not set', ->
      errorHandler = createSpy()
      request = makeRequest()
      request.on('error', errorHandler)

      client.config.credentials.accessKeyId = null
      request.send()

      client.config.credentials.accessKeyId = 'akid'
      client.config.credentials.secretAccessKey = null
      request.send()

      expect(errorHandler).toHaveBeenCalled()
      AWS.util.arrayEach errorHandler.calls, (call) ->
        expect(call.args[0].error instanceof Error).toBeTruthy()
        expect(call.args[0].error.code).toEqual('SigningError')
        expect(call.args[0].error.message).toMatch(/Missing credentials in config/)

    it 'sends error event if region is not set', ->
      client.config.region = null
      request = makeRequest(->)

      call = errorHandler.calls[0]
      expect(errorHandler).toHaveBeenCalled()
      expect(call.args[0].error instanceof Error).toBeTruthy()
      expect(call.args[0].error.code).toEqual('SigningError')
      expect(call.args[0].error.message).toMatch(/Missing region in config/)

  describe 'httpData', ->
    beforeEach ->
      helpers.mockHttpResponse 200, {}, ['FOO', 'BAR', 'BAZ', 'QUX']

    it 'emits httpData event on each chunk', ->
      calls = []

      # register httpData event
      request = makeRequest()
      request.on('httpData', (chunk) -> calls.push(chunk))
      request.send()

      expect(calls).toEqual(['FOO', 'BAR', 'BAZ', 'QUX'])

    it 'clears default httpData event if another is added (allow streaming)', ->
      request = makeRequest()
      request.on('httpData', ->)
      response = request.send()

      expect(response.httpResponse.body).toEqual('')

  describe 'retry', ->
    it 'retries a request with a set maximum retries', ->
      sendHandler = createSpy('send')
      client.config.maxRetries = 10

      # fail every request with a fake networking error
      helpers.mockHttpResponse
        code: 'NetworkingError', message: 'Cannot connect'

      request = makeRequest()
      request.on('send', sendHandler)
      response = request.send()

      expect(retryHandler).toHaveBeenCalled()
      expect(errorHandler).toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()
      expect(successHandler).not.toHaveBeenCalled()
      expect(response.retryCount).toEqual(client.config.maxRetries);
      expect(sendHandler.calls.length).toEqual(client.config.maxRetries + 1)

    it 'retries with falloff', ->
      helpers.mockHttpResponse
        code: 'NetworkingError', message: 'Cannot connect'
      makeRequest(->)
      expect(delays).toEqual([30, 60, 120])

    it 'retries if status code is >= 500', ->
      helpers.mockHttpResponse 500, {}, ''

      makeRequest (err) ->
        expect(err).toEqual
          code: 500,
          message: null,
          statusCode: 500
          retryable: true
        expect(@retryCount).
          toEqual(client.config.maxRetries)

    it 'should not emit error if retried fewer than maxRetries', ->
      spyOn(AWS.HttpClient, 'getInstance').andReturn handleRequest: (req, resp) ->
        if resp.retryCount < 2
          req.emit('httpError', {code: 'NetworkingError', message: "FAIL!"}, resp)
        else
          req.emit('httpHeaders', resp.retryCount < 2 ? 500 : 200, {}, resp)
          req.emit('httpData', 'foo', resp)
          req.emit('httpDone', resp)

      response = makeRequest(->)

      expect(totalWaited).toEqual(90)
      expect(response.retryCount).toBeLessThan(client.config.maxRetries)
      expect(response.data).toEqual('foo')
      expect(errorHandler).not.toHaveBeenCalled()

  describe 'success', ->
    it 'emits success on a successful response', ->
      # fail every request with a fake networking error
      helpers.mockHttpResponse 200, {}, 'Success!'

      response = makeRequest(->)

      expect(retryHandler).not.toHaveBeenCalled()
      expect(errorHandler).not.toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()
      expect(successHandler).toHaveBeenCalled()
      expect(response.retryCount).toEqual(0);

  describe 'error', ->
    it 'emits error if error found and should not be retrying', ->
      # fail every request with a fake networking error
      helpers.mockHttpResponse 400, {}, ''

      response = makeRequest(->)

      expect(retryHandler).not.toHaveBeenCalled()
      expect(errorHandler).toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()
      expect(successHandler).not.toHaveBeenCalled()
      expect(response.retryCount).toEqual(0);

    it 'emits error if an error is set in extractError', ->
      error = code: 'ParseError', message: 'error message'
      extractDataHandler = createSpy('extractData')

      helpers.mockHttpResponse 400, {}, ''

      request = makeRequest()
      request.on('extractData', extractDataHandler)
      request.on('extractError', (resp) -> resp.error = error)
      response = request.send()

      expect(response.error).toBe(error)
      expect(extractDataHandler).not.toHaveBeenCalled()
      expect(retryHandler).not.toHaveBeenCalled()
      expect(errorHandler).toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()

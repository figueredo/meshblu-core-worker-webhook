_               = require 'lodash'
request         = require 'request'
async           = require 'async'
MeshbluHttp     = require 'meshblu-http'
SimpleBenchmark = require 'simple-benchmark'
debug           = require('debug')('meshblu-core-worker-webhook:worker')

class Worker
  constructor: (options={})->
    { @privateKey, @meshbluConfig } = options
    { @client, @queueName, @queueTimeout, @logFn } = options
    { @jobLogger, @workLogger, @jobLogSampleRate, @logFn } = options
    throw new Error('Worker: requires client') unless @client?
    throw new Error('Worker: requires jobLogger') unless @jobLogger?
    throw new Error('Worker: requires jobLogSampleRate') unless @jobLogSampleRate?
    throw new Error('Worker: requires workLogger') unless @workLogger?
    throw new Error('Worker: requires queueName') unless @queueName?
    throw new Error('Worker: requires queueTimeout') unless @queueTimeout?
    throw new Error('Worker: requires privateKey') unless @privateKey?
    throw new Error('Worker: requires meshbluConfig') unless @meshbluConfig?
    delete @meshbluConfig.uuid
    delete @meshbluConfig.token
    debug 'using meshblu config', @meshbluConfig
    @logFn ?= console.error
    @shouldStop = false
    @isStopped = false

  do: (callback) =>
    workBenchmark = new SimpleBenchmark { label: 'meshblu-core-worker:worker' }
    @client.brpop @queueName, @queueTimeout, (error, result) =>
      return callback error if error?
      return callback() unless result?

      [ queue, jobRequest ] = result
      try
        jobRequest = JSON.parse jobRequest
      catch error
        return callback error

      jobBenchmark = new SimpleBenchmark { label: 'meshblu-core-worker:job' }
      @_logWorker {workBenchmark, jobRequest}, (error) =>
        @logFn error.stack if error?
        @_process jobRequest, (error, jobResponse) =>
          @logFn error.stack if error?
          @_logJob { error, jobBenchmark, jobResponse, jobRequest }, (error) =>
            @logFn error.stack if error?
            callback()

    return # avoid returning promise

  run: =>
    async.doUntil @do, (=> @shouldStop), =>
      @isStopped = true

  stop: (callback) =>
    @shouldStop = true

    timeout = setTimeout =>
      clearInterval interval
      callback new Error 'Stop Timeout Expired'
    , 5000

    interval = setInterval =>
      return unless @isStopped?
      clearInterval interval
      clearTimeout timeout
      callback()
    , 250

  _process: ({ requestOptions, revokeOptions, signRequest }, callback) =>
    requestOptions = _.defaults timeout: 5000, requestOptions
    @_request { options: requestOptions, signRequest }, (requestError, jobResponse) =>
      return callback requestError, jobResponse if signRequest
      return callback requestError, jobResponse unless revokeOptions?.token?
      @_revoke revokeOptions, (revokeError) =>
        error = requestError ? revokeError ? null
        callback error, jobResponse

  _revoke: ({ uuid, token }, callback) =>
    _meshbluConfig = _.cloneDeep @meshbluConfig
    _meshbluConfig.uuid = uuid
    _meshbluConfig.token = token
    meshbluHttp = new MeshbluHttp _meshbluConfig
    debug 'revoking', { uuid, token }
    meshbluHttp.revokeToken uuid, token, (error) =>
      return callback error if error?
      callback null

  _request: ({ options, signRequest }, callback) =>
    debug 'request.options', options
    debug 'request.signRequest', signRequest
    options.httpSignature = @_createSignatureOptions() if signRequest
    request options, (error, response) =>
      return callback error if error?
      debug 'response.code', response.statusCode
      callback null, response

  _createSignatureOptions: =>
    return {
      keyId: 'meshblu-webhook-key'
      key: @privateKey
      headers: [ 'date', 'X-MESHBLU-UUID' ]
    }

  _formatRequestLog: ({ requestOptions, revokeOptions, signRequest }) =>
    return {
      metadata: {
        signRequest: signRequest || false,
        revokeOptions: {
          uuid: revokeOptions?.uuid
          hasToken: revokeOptions?.token?
        }
      }
    }

  _getJobLogs: =>
    jobLogs = []
    if Math.random() < @jobLogSampleRate
      jobLogs.push 'sampled'
    return jobLogs

  _formatErrorLog: (error) =>
    return {
      metadata:
        code: error?.code ? 500
        success: false
        jobLogs: @_getJobLogs()
        error:
          message: error?.message ? 'Unknown Error'
    }

  _formatResponseLog: (jobResponse) =>
    code = _.get(jobResponse, 'statusCode') ? 500
    debug 'code', code
    return {
      metadata: {
        code: code
        success: code > 399
        jobLogs: @_getJobLogs()
      }
    }

  _logJob: ({ error, jobRequest, jobResponse, jobBenchmark }, callback) =>
    _request = @_formatRequestLog jobRequest
    _response = @_formatResponseLog jobResponse
    _response = @_formatErrorLog error if error
    debug '_logJob', _request, _response
    @jobLogger.log {request:_request, response:_response, elapsedTime: jobBenchmark.elapsed()}, callback

  _logWorker: ({ jobRequest, workBenchmark }, callback) =>
    _request = @_formatRequestLog jobRequest
    _response =
      metadata:
        code: 200
        success: true
        jobLogs: @_getJobLogs()
    debug '_logWorker', _request, _response
    @workLogger.log {request:_request, response:_response, elapsedTime: workBenchmark.elapsed()}, callback

module.exports = Worker

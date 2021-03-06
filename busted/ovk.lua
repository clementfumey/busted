-- ----------------------------------------------------------------------------
-- Extends busted environment to support overkiz event loop and              --
-- enable async tests.                                                       --
-- Add the following functions:                                              --
--   * async_it: to set the current test as async                            --
--     It start a new poller if no one exists                                --
--   * done in  async_it to set the test as finished                         --
--   * before_each_async: called after the poller creation                   --
--     before running async_it                                               --
--   * after_each_async: called after async_it execution                     --
--                                                                           --
-- ----------------------------------------------------------------------------
local function init(busted)
  local block = require 'busted.block'(busted)

  busted.overkiz_env = {}

  local async_it = function(element)
    -- trick: set async_it element.descriptor as it
    -- because output handlers only allows 'failure' inside 'it' block
    -- otherwise it will be treated as 'error'
    element.descriptor = 'it'

    local parent = busted.context.parent(element)
    local finally

    if not block.lazySetup(parent) then
      -- skip test if any setup failed
      return
    end

    if not element.env then element.env = {} end

    block.rejectAll(element)
    element.env.finally = function(fn) finally = fn end
    element.env.pending = busted.pending

    local pass, ancestor = block.execAll('before_each', parent, true)

    if pass then
      local status = busted.status('success')
      if busted.safe_publish('test', { 'test', 'start' }, element, parent) then

        local timer
        local timed_out = false
        local pass_async, ancestor_async

        -- check if current env contains a poller, if not, create a new one
        if not busted.overkiz_env.poller then
          import 'Overkiz.Poller'
          busted.overkiz_env.poller = Poller()
        end

        -- create a timeout timer for current test
        import 'Overkiz.Time'
        import 'Overkiz.Timer'
        timer = Timer.Real()

        function timer:expired()
          timed_out = true
          busted.overkiz_env.poller:stop()

          -- print error message in busted
          local message = element.trace.short_src..':'..element.trace.currentline..': '..'Async test timed out.'
          busted.publish({'failure', element.descriptor }, element, busted.context.parent(element), message, '')
          status:update(busted.status('failure'), message)
          block.dexecAll('after_each_async', ancestor_async, true)
        end

        pass_async, ancestor_async = block.execAll('before_each_async', ancestor, true)

        if pass_async then

          -- add set_timeout method to env to override default timeout value
          local timeout = 1000
          element.env.set_timeout = function(value)
            timer:setTime(Time.Real(Time.Elapsed(0, value * 1e6)), true)
          end

          timer:setTime(Time.Real(Time.Elapsed(0, timeout * 1e6)), true)
          timer:start()

          -- add a done() method to environment to set test as finished
          element.env.done = function(user_status, msg)
            if user_status == false then
              local message = element.trace.short_src..':'..element.trace.currentline..': '..
                tostring(msg or 'unspecified failure, use done(false, "failure description")')
              busted.publish({'failure', element.descriptor }, element, busted.context.parent(element), message, '')
              status:update(busted.status('failure'), message)
            end

            block.dexecAll('after_each_async', ancestor_async, true)
            if timer then timer:stop() end
            if busted.overkiz_env.poller then
              busted.overkiz_env.poller:stop()
            end
          end

          -- exec test code
          local ret_status, return_from_test = busted.safe('it', element.run, element, function()
              if busted.overkiz_env.poller then
                busted.overkiz_env.poller:stop()
              end
          end)
          status:update(ret_status)

          -- start poller to wait for current async test
          if busted.overkiz_env.poller then
            busted.overkiz_env.poller:loop()
          end

          if finally then
            block.reject('pending', element)
            status:update(busted.safe('finally', finally, element))
          end
        else
          block.dexecAll('after_each_async', ancestor_async, true)
        end -- end if pass_async then
      else
        status = busted.status('error')
      end
      busted.safe_publish('test', { 'test', 'end' }, element, parent, tostring(status))
    end

    block.dexecAll('after_each', ancestor, true)
  end

  busted.register('async_it', async_it)
  busted.register('spec', 'async_it')
  busted.register('test', 'async_it')

  busted.register('before_each_async', { envmode = 'unwrap' })
  busted.register('after_each_async', { envmode = 'unwrap' })

  return busted
end

return setmetatable({}, {
  __call = function(self, busted)
    init(busted)

    return setmetatable(self, {
      __index = function(self, key)
        return busted.api[key]
      end,

      __newindex = function(self, key, value)
        error('Attempt to modify busted')
      end
    })
  end
})

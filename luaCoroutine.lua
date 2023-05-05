local _ENV = moduleDef("coFuture", {})

-- 字符串分割（正则无效）
function split(str, delimiter, isToNumber, maxSplit)
    maxSplit = maxSplit or #str
    local result = {}
    local from  = 1
    local v
    local cSplit = 0
    local delim_from, delim_to = string.find(str, delimiter, from, true)
    while delim_from and cSplit < maxSplit do
        v = string.sub(str, from , delim_from-1 )
        if isToNumber then
            v = tonumber(v)
        end
        table.insert(result, v)
        cSplit = cSplit + 1
        from  = delim_to + 1
        delim_from, delim_to = string.find( str, delimiter, from, true)
    end
    v = string.sub( str, from)
    if isToNumber then
        v = tonumber(v) 
    end
    table.insert(result, v)
    return result
end

local function __initClass(cls)
	local cls_mt = {__index = cls}
	function cls:new(...)
		local o = {}
		setmetatable(o, cls_mt)
		if cls.ctor ~= nil then
			o:ctor(...)
		end
		return o
	end
end

--[[
	
classDef("TestCls", {
	staticVar1 = 100,
	staticVar2 = "kaka"
})

-- 类的构造方法
function TestCls:ctor(p1, p2)
	self.var1 = p1
	self.var2 = p2
end

function TestCls:func1()
	print("member func", self.var1, self.var2, TestCls.staticVar1, TestCls.staticVar2)
end

----------------------
-- 外部调用

local inst = TestCls:new(1, 2)
inst:func1()

]]
function classDef(sClsName, cls)
	if not _G[sClsName] then
		if type(cls) == "table" then
			_G[sClsName] = cls
		elseif type(cls) == "function" then
			_G[sClsName] = cls()
		else
			assert(cls == nil)
			_G[sClsName] = {}
		end

		__initClass(_G[sClsName])

	end
	return _G[sClsName]
end

function createClass()
	local cls = {}
	__initClass(cls)
	return cls
end

function classDefCopyTable(tCls, tParentCls)
    for k, v in pairs(tParentCls) do
        tCls[k] = v
    end
end

COROUTINE_DEAD_DESC = "cannot resume dead coroutine"

local unpack = unpack or table.unpack

function safePack(...)
	local params = {...}
	params.n = select('#', ...)
	return params
end

function safeUnpack(tSafePack)
	return unpack(tSafePack, 1, tSafePack.n)
end

-- @region class co-exception
EXCEPTION_TYPE_RETURN = 1
EXCEPTION_TYPE_BADYIELDERROR = 2
EXCEPTION_TYPE_CANCELLED = 3
EXCEPTION_TYPE_COROUTINE_DEAD = 4

classDef("Return", {
    exception_type = EXCEPTION_TYPE_RETURN,
    message = "Return",
})
function Return:ctor(...)
    local val = safePack(...)
    self.value = val
end

classDef("BadYieldError", {
    exception_type = EXCEPTION_TYPE_BADYIELDERROR,
    message = "BadYieldError",
})
function BadYieldError:ctor(val)
    self.value = val
end

classDef("Cancelled", {
    exception_type = EXCEPTION_TYPE_CANCELLED,
    message = "Cancelled",
})
function Cancelled:ctor(val)
    self.value = val
end

classDef("CoroutineDead", {
    exception_type = EXCEPTION_TYPE_COROUTINE_DEAD,
    message = "CoroutineDead",
})
function Cancelled:ctor(val)
    self.value = val
end
-- end region class co-exception

-- @region class Future
classDef("Future", {
    CLS_FUTURE = true,
})

function Future:ctor()
    self._done = false
    self._result = nil
    self._exc_info = nil
    self._callbacks = {}
end

function Future:done()
    return self._done
end

function Future:result()
    if self._result ~= nil then
        return self._result
    end
    if self._exc_info ~= nil then
        error(self._exc_info)
    end
    return self._result
end

function Future:add_done_callback(func)
    if self._done then
        func(self)
    else
        table.insert(self._callbacks, func)
    end
end

function Future:_set_done()
    self._done = true
    local nLen = #self._callbacks
    local function error_func(sMsg, nLv)
        print(sMsg)
    end
    for i=1, nLen do
        local cb = self._callbacks[i]
        xpcall(cb, error_func, self)
    end
    self._callbacks = nil
end

function Future:set_result(result)
    self._result = result
    self:_set_done()
end

function Future:set_exc_info(exc_info)
    -- 为了统一输出，尽量传string进来
    self._exc_info = exc_info
	self:_set_done()
end

function Future:cancel()
    self._exc_info = Cancelled:new("user_cancel")
	self:_set_done()
end
-- end region class Future

-- @region class IOLoop
classDef("IOLoop", {})

function IOLoop:ctor()
    self._callbacks = {}
	self._running = false
end

function IOLoop:add_future(future, callback)
    assert(type(future) == "table" and future.CLS_FUTURE)
    future:add_done_callback(function(future)
        return self:add_callback(callback, future)
    end)
end

function IOLoop:add_callback(callback, ...)
    local ret = callback(...)
    if ret ~= nil then
        local function convert()
            ret = convert_yielded(ret)
        end
        local function catch(oError, nLv)
            if type(oError) == "table" and oError.exception_type and oError.exception_type == EXCEPTION_TYPE_BADYIELDERROR then
                return
            end
        end
        xpcall(convert, catch)
        self:add_future(ret, function(future)
            return future:result()
        end)
    end
end

function currentIOLoop()
    if not g_IOLoop then
        g_IOLoop = IOLoop:new()
    end
    return g_IOLoop
end
-- end region class IOLoop

-- @region class Runner
local function _checkLocals()
end

function convert_yielded(yielded)
    if type(yielded) == "table" and yielded.CLS_FUTURE then
        return yielded
    end
    error(BadYieldError:new("yielded unknown object"..type(yielded)))
end

_null_future = Future:new()
_null_future:set_result(nil)

classDef("Runner", {})

function Runner:ctor(oCoroutine, result_future, first_yielded)
    -- if isDebug() then
    --     _checkLocals()
    -- end
    self.coroutine = oCoroutine
    self.result_future = result_future
    self.future = _null_future
    self.running = false
	self.finished = false
    self.io_loop = currentIOLoop()
    if self:handle_yield(first_yielded) then
        self:run()
    end
end

function Runner:run()
    if self.running or self.finished then
        return
    end
    local function startLoop()
        self.running = true
        while true do
            local future = self.future
            if not future:done() then
                return
            end
            self.future = nil
            local value
            xpcall(function()
                value = future:result()
            end, function(oError, nLv)
                coroutine.close(self.coroutine)
            end)
            local bStatus, yielded = coroutine.resume(self.coroutine, value)
            if not bStatus then
                if yielded == COROUTINE_DEAD_DESC then
                    self.finished = true
                    self.future = _null_future
                    self.result_future:set_result(nil)
                    self.result_future = nil
                    return
                elseif type(yielded) == "table" and yielded.exception_type and yielded.exception_type == EXCEPTION_TYPE_RETURN then
                    self.finished = true
                    self.future = _null_future
                    self.result_future:set_result(yielded.value)
                    self.result_future = nil
                    return
                elseif type(yielded) == "table" and yielded.exception_type and yielded.exception_type == EXCEPTION_TYPE_CANCELLED then
                    self.finished = true
					self.future = _null_future
					self.result_future:set_exc_info(yielded.value)
					self.result_future = nil
					return
                else
                    self.finished = true
					self.future = _null_future
					self.result_future:set_exc_info(tostring(yielded))
					self.result_future = nil
					return                    
                end
            end
            -- if isDebug() then
            --     _checkLocals()
            -- end
            if not self:handle_yield(yielded) then
                return
            end
        end
    end
    pcall(startLoop)
    self.running = false
end

function Runner:handle_yield(yielded)
    xpcall(function(yielded)
            self.future = convert_yielded(yielded)
        end, function(oError, nLv)
            if type(oError) == "table" and oError.exception_type and oError.exception_type == EXCEPTION_TYPE_BADYIELDERROR then
                self.future = Future:new()
                self.future:set_exc_info(oError.value)
        end
    end, yielded)

    if not self.future:done() then
        self.io_loop:add_future(self.future, function(future)
            return self:run()
        end)
        return false
    end
    return true
end
-- end region class Runner

function coFuture(func, ...)
    local future = Future:new()
    local oCoroutine = coroutine.create(func)
    local bStatus, result = coroutine.resume(oCoroutine, ...)
    local trueResult
    -- coroutine.status只会是dead和suspended, 暂不支持coFuture的func中延续别的coroutine，所以不会出现normal, 并且resume之后该coroutine不会为running

    if not bStatus then
        if type(result) == "table" and result.exception_type and result.exception_type == EXCEPTION_TYPE_RETURN then
            trueResult = result.value
        else
            future:set_exc_info(result)
			return future
        end
    else
        if coroutine.status(oCoroutine) == "dead" then
            trueResult = result
        elseif coroutine.status(oCoroutine) == "suspended" then
            Runner:new(oCoroutine, future, result)
            return future
        end
    end
    future:set_result(trueResult)
    return future
end

function waitMultiFuture(tFutures)
    local tUnfinish = {}
    for i = 1, #tFutures do
        tUnfinish[tFutures[i]] = true
    end
    local oFuture = Future:new()
    if #tFutures == 0 then
        oFuture:set_result({})
        return oFuture
    end

    local function _callBack(f)
        tUnfinish[f] = nil
        for f, b in pairs(tUnfinish) do
            if b == true then
                return
            end
        end
        local tResult = {}
        for i = 1, #tFutures do
            local f = tFutures[i]
            xpcall(function()
                table.insert(tResult, f:result())
            end, function(oError, nLv)
                if type(oError) == "string" then
                    oFuture:set_exc_info(oError)
                elseif type(oError) == "table" and oError.exception_type then
                    oFuture:set_exc_info(oError.value)
                else
                    oFuture:set_exc_info(tostring(oError))
                end
				return
            end)
        end
        oFuture:set_result(tResult)
    end
    for i = 1, #tFutures do
        local f = tFutures[i]
        f:add_done_callback(_callBack)
    end
    return oFuture
end

function coMessager(sendFunc, sRecvFuncName, ...)
    local tRecvFuncName = split(sRecvFuncName, '.')
    local sModuleName, sFuncName = tRecvFuncName[1], tRecvFuncName[2]
    if sModuleName and sFuncName and sModuleName ~= "" and sFuncName ~= "" then
        local oFuture = Future:new()
        _G[sModuleName][sFuncName] = function(...)
            local tArgs = safePack(...)
            oFuture:set_result(tArgs)
        end
        sendFunc(...)
        return oFuture
    else
        print("Wrong recv func name!")
    end
end

function coYieldUnpack(oFuture)
    local tArgs = coroutine.yield(oFuture)
    return safeUnpack(tArgs)
end

function getWeakRefRole(nRoleId)
    local tWeakRef = {}
    local tMeta = {__mode = 'v'}
    setmetatable(tWeakRef, tMeta)
    tWeakRef.tRole = RoleMod.getRole(nRoleId)
    return tWeakRef
end

function isWeakRefRoleExit(tWeakRef)
    if not tWeakRef.tRole then
        return false
    else
        return true
    end
end

_G.getWeakRefRole = getWeakRefRole
_G.isWeakRefRoleExit = isWeakRefRoleExit

_G.waitMultiFuture = waitMultiFuture
_G.coYieldUnpack = coYieldUnpack
_G.coMessager = coMessager
_G.coFuture = coFuture

-- exmaple: 

-- 1. 协议/rpc回调 c->s->c
-- client:
-- function trueGmFuture()
--     return coFuture(function()
--         local nID = coYieldUnpack(coMessager(Messager.SeriesEventSvrMod.testsvr, "SeriesEventCltMod.testclt", 121))
--     end)
-- end

-- server:
-- function testsvr(nRoleId, nID)
--     Messager.SeriesEventCltMod.testclt(nRoleId, 38)
-- end

-- 2. 异步函数返回
-- function trueGmFuture()
--     return coFuture(function()
--         local nID = coYieldUnpack(coMessager(Messager.SeriesEventSvrMod.testsvr, "SeriesEventCltMod.testclt", 121))
--         error(Return:new(nID))
--     end)
-- end

-- function gmFuture()
--     return coFuture(function()
--         local a = coYieldUnpack(trueGmFuture())
--     end)
-- end

-- 3. 异步加载回调
-- function load()
--     local oFuture = Future:new()
--     xxxx.load(function(data)
--         oFuture.set_result(data)
--     end)
--     local data = coYieldUnpack(oFuture)
--     ...
-- end

-- 注意：服务端使用协程时不可以将玩家对象传入，会影响玩家下线是对象的卸载，这里提供了getWeakRefRole来获取玩家对象的弱引用
--     每次异步后需要通过接口isWeakRefRoleExit判断玩家对象是否还存在
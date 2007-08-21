
--[[
=head1 NAME

jive.net.HttpPool - Manages a set of HTTP sockets.

=head1 DESCRIPTION

This class manages 2 queues of a requests, processed using a number
of HTTP sockets (see L<jive.net.SocketHttp>). The sockets are opened
dynamically as the queue size grows, and are closed once all requests
have been serviced.
jive.net.HttpPool defines 2 priorities: basic and high. High priority
requests are serviced before basic ones.

=head1 SYNOPSIS

 -- create a pool for http://192.168.1.1:9000
 -- with a max of 4 connections, threshold of 2 requests
 local pool = HttpPool(jnt, "192.168.1.1", 9000, 4, 2, 'slimserver'),

 -- queue a request
 pool:queue(aRequest)

 -- queue a request, with high priority
 pool:queuePriority(anImportantRequest)


=head1 FUNCTIONS

=cut
--]]
-----------------------------------------------------------------------------
-- Convention: functions/methods starting with t_ are executed in the thread
-----------------------------------------------------------------------------


-- stuff we use
local assert, ipairs, tostring = assert, ipairs, tostring

local table           = require("table")
local math            = require("math")

local oo              = require("loop.base")

local SocketHttpQueue = require("jive.net.SocketHttpQueue")
local Timer           = require("jive.ui.Timer")
local perfs           = require("jive.utils.perfs")

local log             = require("jive.utils.log").logger("net.http")

local KEEPALIVE_TIMEOUT = 300000 -- timeout idle connections after 300 seconds

-- jive.net.HttpPool is a base class
module(..., oo.class)


--[[

=head2 jive.net.HttpPool(jnt, ip, port, quantity, threshold, name)

Creates an HTTP pool named I<name> to interface with the given I<jnt> 
(a L<jive.net.NetworkThread> instance). I<name> is used for debugging and
defaults to "". I<ip> and I<port> are the IP address and port of the HTTP server.

I<quantity> is the maximum number of connections to open, depending on
the number of requests waiting for service. This is controlled using the
I<threshold> parameter which indicates the ratio of requests to connections.
For example, if I<threshold> is 2, a single connection is used until 2 requests
are pending, at which point a second connection is used. A third connection
will be opened as soon as the number of queued requests reaches 6.

=cut
--]]
function __init(self, jnt, ip, port, quantity, threshold, name)
--	log:debug("HttpPool:__init(", name, ", ", ip, ", ", port, ", ", quantity, ")")

	-- let used classes worry about ip, port existence
--	assert(jnt)
	
	local obj = oo.rawnew(self, {
		jnt           = jnt,
		poolName      = name or "",
		pool          = {
			active    = 1,
			threshold = threshold or 10,
			jshq      = {}
		},
		reqQueue      = {},
		reqQueueCount = 0,
		timeout_timer = nil,
	})
	
	
	-- init the pool
	local q = quantity or 1
	for i = 1, q do
		obj.pool.jshq[i] = SocketHttpQueue(jnt, ip, port, obj, obj.poolName .. i)
	end
	
	return obj
end


--[[

=head2 jive.net.HttpPool:free()

Frees the pool, close and free all connections.

=cut
--]]
function free(self)
	for i=1,#self.pool.jshq do
		self.pool.jshq[i]:free()
		self.pool.jshq[i] = nil
	end
end


--[[

=head2 jive.net.HttpPool:queue(request)

Queues I<request>, a L<jive.net.RequestHttp> instance. All previously
queued requests will be serviced before this one.

=cut
--]]
function queue(self, request)
	perfs.check('Pool Queue', request, 1)
--	log:warn(self, " enqueues ", request)
	self.jnt:perform(function() self:t_queue(request, 1) end)
end


--[[

=head2 jive.net.HttpPool:queuePriority(request)

Queues I<request>, a L<jive.net.RequestHttp> instance. All previously
priority queued requests will be serviced before this one, but the request
will be serviced before normal requests.

=cut
--]]
function queuePriority(self, request)
	perfs.check('Pool Priority Queue', request, 1)
--	log:warn(self, " priority enqueues ", request)
	self.jnt:perform(function() self:t_queue(request, 0) end)
end


-- t_queue
-- queues a request
function t_queue(self, request, priority )
--	log:debug(self, ":t_queue()")
	
	if not self.reqQueue[priority] then
		self.reqQueue[priority] = {}
	end
	
	table.insert(self.reqQueue[priority], request)
	self.reqQueueCount = self.reqQueueCount + 1
	
	-- calculate threshold
	local active = math.floor(self.reqQueueCount / self.pool.threshold) + 1
	if active > #self.pool.jshq then
		active = #self.pool.jshq
	end
	self.pool.active = active
	
--	log:debug(self, ":", self.reqQueueCount, " requests, ", self.pool.active, " connections")

	perfs.check('', request, 2)

	-- kick all active queues
	for i = 1, self.pool.active do
		self.pool.jshq[i]:t_sendDequeueIfIdle()
	end
end


-- t_dequeue
-- returns a request if there is any
-- called by SocketHttpQueue
function t_dequeue(self, socket)
	log:debug(self, ":t_dequeue()")
		
	for i, queue in ipairs(self.reqQueue) do
		local request = table.remove(self.reqQueue[i], 1)
		if request then
			self.reqQueueCount = self.reqQueueCount - 1
--			log:warn(self, " dequeues ", request)
			perfs.check('', request, 3)
			
			if self.timeout_timer then
				self.timeout_timer:stop()
				self.timeout_timer = nil
			end
			
			return request, false
		end
	end
	
	self.reqQueueCount = 0
	
	-- close the first connection after a timeout expires
	if not self.timeout_timer then
		self.timeout_timer = Timer(
			KEEPALIVE_TIMEOUT,
			function()
				log:debug(self, ": closing idle connection")
				self.pool.jshq[1]:t_close('keep-alive timeout')
			end,
			true -- run once
		)
		self.timeout_timer:start()
	end			

	-- close all but the first one (active = 1)
	return nil, (socket != self.pool.jshq[1])
end


--[[

=head2 tostring(aPool)

if I<aPool> is a L<jive.net.HttpPool>, prints
 HttpPool {name}

=cut
--]]
function __tostring(self)
	return "HttpPool {" .. tostring(self.poolName) .. "}"
end


--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]


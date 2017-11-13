local responses = require "kong.tools.responses"
local utils = require "kong.tools.utils"
local sha512 = require('sha512')
local kutils = require ("kong.plugins.keystone.utils")
local time = require "kong.tools.timestamp"

local function list_users(self, dao_factory, helpers)
    local resp = {
        links = {
            next = "null",
            previous = "null",
            self = self:build_url(self.req.parsed_url.path)
        },
        users = {}
    }

    local domain_id = self.params.domain_id
    local enabled = kutils.bool(self.params.enabled)
    local idp_id = self.params.idp_id
    local name = self.params.name
    local password_expires_at = self.params.password_expires_at
    local protocol_id = self.params.protocol_id
    local unique_id = self.params.unique_id

    local args = ( domain_id ~= nil or enabled ~= nil ) and { domain_id = domain_id, enabled = enabled } or nil
    local users_info, err = dao_factory.user:find_all(args)
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:find_all(...)"})
    end
    if not next(users_info) then
        return responses.send_HTTP_OK(resp)
    end

    local num = 0
    for i = 1, #users_info do
        local fit = true
        local id = users_info[i].id
        local fed_user, err = dao_factory.federated_user:find_all({user_id = id, idp_id = idp_id, protocol_id = protocol_id, unique_id = unique_id})
        if err then
            fit = false
            kutils.handle_dao_error(resp, err, "dao_factory.federated_user:find_all")
        elseif idp_id or protocol_id or unique_id then
            if not next(fed_user) then
                fit = false
            end
        elseif fed_user[1] then
            users_info[i].idp_id = fed_user[1].idp_id
            users_info[i].protocol_id = fed_user[1].protocol_id
            users_info[i].unique_id = fed_user[1].unique_id
        else
            users_info[i].idp_id = "null"
            users_info[i].protocol_id = "null"
            users_info[i].unique_id = "null"
        end

        local temp1, err1 = dao_factory.local_user:find_all({user_id = id, name = name})
        local temp2, err2 = dao_factory.nonlocal_user:find_all({user_id = id, name = name})
        if err1 or err2 then
            fit = false
            if err1 then kutils.handle_dao_factory(resp, err1, "dao_factory.local_user:find_all") end
            if err2 then kutils.handle_dao_factory(resp, err2, "nondao_factory.local_user:find_all") end
        elseif name then
            if not (next(temp1) or next(temp2)) then
                fit = false
            end
        elseif next(temp1) or next(temp2) then
            users_info[i].name = next(temp1) and temp1[1].name or temp2[1].name
        end

-- TODO password_expires_at={operator}:{timestamp}, no parsing by the operator
--        local temp, err = dao_factory.password:find_all({local_user_id = id, expires_at = password_expires_at})
        local temp, err = {}, nil
        if err then
                fit = false
                kutils.handle_dao_error(resp, err, "dao_factory.password:find_all")
        elseif password_expires_at then
            if not next(temp) then
                fit = false
            end
        elseif next(temp) then
            users_info[i].password_expires_at = temp[1].expires_at
        else
            users_info[i].password_expires_at = "null"
        end

        if fit then
            num = num + 1
            resp.users[num] = {
                domain_id = users_info[i].domain_id,
                enabled = users_info[i].enabled,
                id = id,
                name = users_info[i].name,
                idp_id = users_info[i].idp_id,
                protocol_id = users_info[i].protocol_id,
                unique_id = users_info[i].unique_id,
                links = {
                    self = resp.links.self .. '/' .. id
                },
                password_expires_at = users_info[i].password_expires_at
            }
        end
    end

    return responses.send_HTTP_OK(resp)
end

local function create_user(self, dao_factory)
    local resp = {
        user = {}
    }
    local user = self.params.user
    if user == nil then
        return responses.send_HTTP_BAD_REQUEST({message = "Request body must have user field"})
    end

    local uname  = user.name
    if uname == nil then
        return responses.send_HTTP_BAD_REQUEST({message = "Request body must have name field in user field"})
    end
    local passwd
    if user.password then
        passwd = {
            password = sha512.crypt(user.password)
        }
    end

    user = {
        domain_id = user.domain_id or kutils.default_domain(dao_factory),
        enabled = kutils.bool(user.enabled) or true,
        default_project_id = user.default_project_id
    }

    local temp1, err1 = dao_factory.local_user:find_all({ name = uname, domain_id = user.domain_id })
    local temp2, err2 = dao_factory.nonlocal_user:find_all({ name = uname, domain_id = user.domain_id })
    if err2 or err2 then
        return responses.send_HTTP_BAD_REQUEST({{error = err1, func = "dao_factory.local_user:find_all"}, {error = err2, func = "dao_factory.nonlocal_user:find_all"}})
    end
    if next(temp1) or next(temp2) then
        return responses.send_HTTP_BAD_REQUEST({message = "User with name " .. uname .. " already exists"})
    end

    user.id = utils.uuid()
--    user.created_at = os.date("%Y-%m-%dT%X+0000") -- time format YYYY-MM-DDTHH:mm:ssZ
--    user.last_active_at = os.date("%Y-%m-%d")
--    user.created_at = os.date("*t")
    user.created_at = os.time()

    local _, err = dao_factory.user:insert(user)
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:insert"})
    end

    resp.user.default_project_id = user.default_project_id
    resp.user.domain_id = user.domain_id
    resp.user.enabled = user.enabled
    resp.user.id = user.id
    resp.user.links = {self = self:build_url(self.req.parsed_url.path)..'/'..resp.user.id}
    resp.user.name = uname
    resp.user.password_expires_at = "null"

    -- if password -> local_user
    -- else -> nonlocal_user
    if passwd then
        local loc_user = {
            id = utils.uuid(),
            user_id = user.id,
            domain_id = user.domain_id,
            name = uname
        }

        passwd.id = utils.uuid()
        passwd.local_user_id = loc_user.id
        passwd.created_at = user.created_at
        local temp, err = dao_factory.password:insert(passwd)
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.password:insert")
            local nonloc_user = {
                user_id = user.id,
                domain_id = user.domain_id,
                name = uname
            }
            local _, err = dao_factory.nonlocal_user:insert(nonloc_user)
            if err then
                kutils.handle_dao_error(resp, err, "dao_factory.nonlocal_user:insert")
            end

        else
            resp.user.password_expires_at = temp.expires_at
            local _, err = dao_factory.local_user:insert(loc_user)
            if err then
                kutils.handle_dao_error(resp, err, "dao_factory.local_user:insert")
            end

        end

    else
        local nonloc_user = {
            domain_id = user.domain_id,
            user_id = user.id,
            name = uname
        }
        local _, err = dao_factory.nonlocal_user:insert(nonloc_user)
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.nonlocal_user:insert")
        end
    end

    return responses.send_HTTP_CREATED(resp)
end

local function get_user_info(self, dao_factory)
    local user_id = self.params.user_id
    local user, err = dao_factory.user:find({id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST(err)
    end
    if not next(user) then
        return responses.send_HTTP_NOT_FOUND({message = "No user with id "..user_id})
    end

    local resp = {
        user = {
            links = {
                self = self:build_url(self.req.parsed_url.path)
            },
            default_project_id = user.default_project_id,
            domain_id = user.domain_id,
            enabled = kutils.bool(user.enabled),
            id = user.id,
            password_expires_at = "null"
        }
    }
    local loc_user, err1 = dao_factory.local_user:find_all({user_id = user_id})
    local nonloc_user, err2 = dao_factory.nonlocal_user:find_all({user_id = user_id})
    if err1 or err2 then
        if err1 then kutils.handle_dao_error(resp, err1, "dao_factory.local_user:find_all") end
        if err2 then kutils.handle_dao_error(resp, err2, "dao_factory.nonlocal_user:find_all") end
    elseif next(loc_user) then
        resp.user.name = loc_user[1].name
        local passwd, err = dao_factory.password:find_all({local_user_id = loc_user[1].id})
        if err then
            kutils.handle_dao_error(resp,  err, "dao_factory.password:find_all")
        else
            resp.user.password_expires_at = passwd.expires_at or "null"
        end

    elseif next(nonloc_user) then
        resp.user.name = nonloc_user[1].name
    else
        return responses.send_HTTP_BAD_REQUEST({message = "No name found for user "..user_id})
    end

    return responses.send_HTTP_OK(resp)
end

local function update_user(self, dao_factory)
    local user_id = self.params.user_id
    local user, err = dao_factory.user:find({id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:find"})
    end
    if not next(user) then
        return responses.send_HTTP_BAD_REQUEST({message = "No user found, check id = "..user_id})
    end

    local uupdate = self.params.user
    if not uupdate then
        return responses.send_HTTP_BAD_REQUEST({message = "No user object detected in request"})
    end

    local loc_user, err1 = dao_factory.local_user:find_all({user_id = user_id})
    local nonloc_user, err2 = dao_factory.nonlocal_user:find_all({user_id = user_id})
    if err1 or err2 then
        return responses.send_HTTP_BAD_REQUEST({{error = err1, func = "dao_factory.local_user:find_all"}}, {error = err2, func = "dao_factory.nonlocal_user:find_all"})
    end
    local loc_user = loc_user[1]
    local nonloc_user = nonloc_user[1]

    local uname = uupdate.name
    if uname or uupdate.domain_id then
        local check_domain = uupdate.domain_id or user.domain_id
        local check_name = uname or loc_user.name or nonloc_user.name
        local temp1, err1 = dao_factory.local_user:find_all({domain_id = check_domain, name = check_name})
        local temp2, err2 = dao_factory.nonlocal_user:find_all({domain_id = check_domain, name = check_name})
        if err1 or err2 then
            return responses.send_HTTP_BAD_REQUEST({{error = err1, func = "dao_factory.local_user:find_all"}}, {error = err2, func = "dao_factory.nonlocal_user:find_all"})
        end
        if next(temp1) then
            if temp1[1].user_id ~= user_id then
                return responses.send_HTTP_BAD_REQUEST({message = "Requested name is already exists in requested domain"})
            end
        elseif next(temp2) then
            if temp2[1].user_id ~= user_id then
                return responses.send_HTTP_BAD_REQUEST({message = "Requested name is already exists in requested domain"})
            end
        end

    end

    local passwd
    if uupdate.password then
        passwd = {
            password= sha512.crypt(uupdate.password)
        }
    end

    uupdate = {
        default_project_id = uupdate.default_project_id,
        domain_id = uupdate.domain_id,
        enabled = kutils.bool(uupdate.enabled)
    }

    if next(uupdate) then
        local err
        user, err = dao_factory.user:update(uupdate, {id = user_id})
        if err then
            return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:update"})
        end
    end
    if uupdate.domain_id then
        if loc_user then
            local _, err = dao_factory.local_user:update({domain_id = uupdate.domain_id}, {id = loc_user.id})
            if err then
                return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.local_user:update"})
            end
            loc_user.domain_id = uupdate.domain_id
        elseif nonloc_user then
            local _, err = dao_factory.nonlocal_user:update({domain_id = uupdate.domain_id}, {domain_id = uupdate.domain_id, name = nonloc_user.name})
            if err then
                return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.nonlocal_user:update"})
            end
            nonloc_user.domain_id = uupdate.domain_id
        end
    end


    local resp = {
        user = {
            links = {
                self = self:build_url(self.req.parsed_url.path)
            },
            default_project_id = user.default_project_id,
            domain_id = user.domain_id,
            enabled = user.enabled,
            id = user.id,
            password_expires_at = "null"
        }
    }

    if uname or passwd then
        if loc_user then
            resp.user.name = loc_user.name
            if uname then
                local temp, err = dao_factory.local_user:find_all({domain_id = user.domain_id, name = uname})
                if err then
                    return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.local_user:find_all"})
                end

                local temp, err = dao_factory.local_user:update({name = uname}, {id = loc_user.id})
                if err then
                    return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.local_user:update"})
                end
                resp.user.name = temp.name
            end


            if passwd then
                passwd.created_at = os.time()
                local temp, err = dao_factory.password:find_all({local_user_id = loc_user.id})
                if err then
                    return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.password:find_all"})
                elseif next(temp) then
                    local passwd, err = dao_factory.password:update(passwd, {id = temp[1].id})
                    if err then
                        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.password:update"})
                    else
                        resp.user.password_expires_at = passwd.expires_at or "null"
                    end
                else
                    passwd.id = utils.uuid()
                    passwd.local_user_id = loc_user.id
                    local passwd, err = dao_factory.password:insert(passwd)
                    if err then
                        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.password:insert"})
                    else
                        resp.user.password_expires_at = passwd.expires_at or "null"
                    end
                end
            end
        elseif nonloc_user then
            resp.user.name = nonloc_user.name
            if uname then
                local _, err = dao_factory.nonlocal_user:update({name = uname}, {domain_id = nonloc_user.domain_id, name = nonloc_user.name})
                if err then
                    return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.nonlocal_user:update"})
                end
                resp.user.name = uname
            end

            if passwd then
                local _, err = dao_factory.nonlocal_user:delete({domain_id = nonloc_user.domain_id, name = nonloc_user.name})
                if err then
                    return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.nonlocal_user:delete"})
                end
                loc_user = {
                    id = utils.uuid(),
                    user_id = user_id,
                    domain_id = nonloc_user.domain_id,
                    name = resp.user.name
                }

                passwd.id = utils.uuid()
                passwd.local_user_id = loc_user.id
                passwd.created_at = os.time()
                local temp, err = dao_factory.password:insert(passwd)
                if err then
                    responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.password:insert"})
                end
                resp.user.password_expires_at = temp.expires_at or "null"

                local loc_user, err = dao_factory.local_user:insert(loc_user)
                if err then
                    return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.local_user:insert"})
                end
            end
        else
            kutils.handle_dao_error(resp, "No local or nonlocal user existed")
            if passwd then
                local loc_user = {
                    id = utils.uuid(),
                    user_id = user_id,
                    domain_id = user.domain_id,
                    name = uname
                }

                passwd.id = utils.uuid()
                passwd.local_user_id = loc_user.id
                passwd.created_at = os.time()
                local temp, err = dao_factory.password:insert(passwd)
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.password:insert")
                    local nonloc_user = {
                        user_id = user.id,
                        domain_id = user.domain_id,
                        name = uname
                    }
                    local _, err = dao_factory.nonlocal_user:insert(nonloc_user)
                    if err then
                        kutils.handle_dao_error(resp, err, "dao_factory.nonlocal_user:insert")
                    end

                else
                    resp.user.password_expires_at = temp.expires_at
                    local _, err = dao_factory.local_user:insert(loc_user)
                    if err then
                        kutils.handle_dao_error(resp, err, "dao_factory.local_user:insert")
                    end

                end

            else
                local nonloc_user = {
                    domain_id = user.domain_id,
                    user_id = user_id,
                    name = uname
                }
                local _, err = dao_factory.nonlocal_user:insert(nonloc_user)
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.nonlocal_user:insert")
                end
            end

        end
    end

    return responses.send_HTTP_OK(resp)
end

local function delete_user(self, dao_factory)
    local resp = {}
    local user_id = self.params.user_id
    local user, err = dao_factory.user:delete({id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST(err)
    end
    if not next(user) then
        return responses.send_HTTP_NOT_FOUND()
    end
        local creds, err = dao_factory.credential:find_all({user_id = user_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.credential:find_all")
        else
            for i = 1, #creds do
                local _, err = dao_factory.credential:delete({id = creds[i].id})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.credential:delete")
                end
            end
        end

        local feds, err = dao_factory.federated_user:find_all({user_id = user_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.federated_user:find_all")
        else
            for i = 1, #feds do
                local _, err = dao_factory.federated_user:delete({id = feds[i].id})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.federated_user:delete")
                end
            end
        end

        local locs, err = dao_factory.local_user:find_all({user_id = user_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.local_user:find_all")
        else
            for i = 1, #locs do
                local _, err = dao_factory.local_user:delete({id = locs[i].id})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.local_user:delete")
                end
                local pass, err = dao_factory.password:find_all({local_user_id = locs[i].id})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.password:find_all")
                else
                    for j = 1, #pass do
                        local _, err = dao_factory.password:delete({id = pass[i].id})
                        if err then
                            kutils.handle_dao_error(resp, err, "dao_factory.password:delete")
                        end
                    end
                end

            end
        end

        local nonlocs, err = dao_factory.nonlocal_user:find_all({user_id = user_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.nonlocal_user:find_all")
        else
            for i = 1, #nonlocs do
                local _, err = dao_factory.nonlocal_user:delete({domain_id = nonlocs[i].domain_id, name = nonlocs[i].name})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.nonlocsl_user:delete")
                end
            end
        end

        local us_grs, err = dao_factory.user_group_membership:find_all({user_id = user_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.user_group_membership:find_all")
        else
            for i = 1, #us_grs do
                local _, err = dao_factory.user_group_membership:delete({user_id = us_grs[i].user_id, group_id = us_grs[i].group_id})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.user_group_membership:delete")
                end
            end
        end

        local us_opts, err = dao_factory.user_option:find_all({user_id = user_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.user_option:find_all")
        else
            for i = 1, #us_opts do
                local _, err = dao_factory.user_option:delete({user_id = us_opts[i].user_id, group_id = us_opts[i].group_id})
                if err then
                    kutils.handle_dao_error(resp, err, "dao_factory.user_option:delete")
                end
            end
        end

    return responses.send_HTTP_NO_CONTENT(resp)
end

local function list_user_groups(self, dao_factory)
    local user_id = self.params.user_id
    local user, err = dao_factory.user:find({id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:find"})
    elseif not user or not next(user) then
        return responses.send_HTTP_BAD_REQUEST({message = "No requested user in database"})
    end

    local resp = {
        links = {
            self = self:build_url(self.req.parsed_url.path),
            next = "null",
            previous = "null"
        },
        groups = {}
    }
    local groups, err = dao_factory.user_group_membership:find_all({user_id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user_group_membership:find_all"})
    end
    for i = 1, #groups do
        local group, err = dao_factory.group:find({id = groups[i].group_id})
        if err then
            kutils.handle_dao_error(resp, err, "dao_factory.group:find")
        end
        resp.groups[i] = group
        resp.groups.extra = nil
        resp.groups[i].links.self =  self:build_url("/v3/groups/"..group.id)
    end

    return responses.send_HTTP_OK(resp)
end

local function list_user_projects(self, dao_factory)
    local user_id = self.params.user_id
    local user, err = dao_factory.user:find({id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:find"})
    elseif not user or not next(user) then
        return responses.send_HTTP_BAD_REQUEST({message = "No requested user in database"})
    end

    local domain_id = user.domain_id
    local resp = {
        links = {
            self = self:build_url(self.req.parsed_url.path),
            next = "null",
            previous = "null"
        },
        projects = {}
    }

    local projects, err = dao_factory.project:find_all({domain_id = domain_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.projects:find_all"})
    end

    for i = 1, #projects do
        resp.projects[i] = projects[i]
        resp.projects.extra = nil
        resp.projects.is_domain = nil
        resp.projects[i].links.self = self:build_url("/v3/projects/"..projects[i].id)
    end

    return responses.send_HTTP_OK(resp)
end

local function change_user_password(self, dao_factory) -- TODO second method by patch
    local user_id = self.params.user_id
    local user, err = dao_factory.user:find({id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.user:find"})
    elseif not user or not next(user) then
        return responses.send_HTTP_BAD_REQUEST({message = "No requested user in database"})
    end

    local uupdate = self.params.user
    local temp, err = dao_factory.local_user:find_all({user_id = user_id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.local_user:find_all"})
    end
    local loc_user = temp[1]
    if not loc_user then
        return responses.send_HTTP_BAD_REQUEST({message = "User is not local"})
    end

    local temp, err = dao_factory.password:find_all({local_user_id = loc_user.id})
    if err then
        return responses.send_HTTP_BAD_REQUEST(err)
    end
    local passwd = temp[1]
    if sha512.verify(uupdate.original_password, passwd.password) ~= true then
        return responses.send_HTTP_BAD_REQUEST({message = "Incorrect original_password"})
    end

    passwd.created_at = os.time()
    passwd.password = sha512.crypt(uupdate.password)
    local passwd, err = dao_factory.password:update(passwd, {id = passwd.id})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.password:update"})
    end

    return responses.send_HTTP_NO_CONTENT()
end

return {
    ["/v3/users"] = {
        GET = function(self, dao_factory)
            list_users(self, dao_factory)
        end,
        POST = function(self, dao_factory)
            create_user(self, dao_factory)
        end
    },
    ["/v3/users/:user_id"] = {
        GET = function(self, dao_factory)
            get_user_info(self, dao_factory)
        end,
        PATCH = function(self, dao_factory)
            update_user(self, dao_factory)
        end,
        DELETE = function(self, dao_factory)
            delete_user(self, dao_factory)
        end
    },
    ["/v3/users/:user_id/groups"] = {
        GET = function(self, dao_factory)
            list_user_groups(self, dao_factory)
        end
    },
    ["/v3/users/:user_id/projects"] = {
        GET = function(self, dao_factory)
            list_user_projects(self, dao_factory)
        end
    },
    ["/v3/users/:user_id/password"] = {
        POST = function(self, dao_factory)
            change_user_password(self, dao_factory)
        end
    }
}
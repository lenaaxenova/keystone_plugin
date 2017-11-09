local responses = require "kong.tools.responses"
local crud = require "kong.api.crud_helpers"
local cjson = require "cjson"
local utils = require "kong.tools.utils"
local kstn_utils = require ("kong.plugins.keystone.utils")

local Project = {}

local subtree = {}
local subtrtee_as_ids = {}

local function get_subtree_as_list(self, dao_factory, project) --not tested
    local child_projects, err = dao_factory.project:find_all({parent_id=project.id})
    if not child_projects then
        return
    end

    for child in child_projects do
        child.links = {self = self:build_url(self.req.parsed_url.path)}
        table.insert(subtree, child)
        get_subtree_as_list(self, dao_factory, child)
    end
end


local function get_subtree_as_ids(self, dao_factory, project) --not tested
    local child_projects, err = dao_factory.project:find_all({parent_id=project.id})
    if not child_projects then
        return
    end

    for child in child_projects do
        table.insert(subtree, child.id)
        get_subtree_as_ids(self, dao_factory, child)
    end
end

local function list_projects(self, dao_factory)
    local resp = {
        links = {
            next = "null",
            previous = "null",
            self = self:build_url(self.req.parsed_url.path)
        },
        projects = {}
    }
    local domain_id = self.params.domain_id
    local enabled = kstn_utils.bool(self.params.enabled)
    local is_domain = kstn_utils.bool(self.params.is_domain)
    local name = self.params.name
    local parent_id = self.params.parent_id

    local args = ( domain_id ~= nil or enabled ~= nil or is_domain ~= nil or name ~= nil or parent_id ~= nil ) and
            { domain_id = domain_id, enabled = enabled, is_domain = is_domain, name = name, parent_id = parent_id } or nil
    local projects, err = dao_factory.project:find_all(args)
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.project:find_all(...)"})
    end
    if not next(projects) then
        return responses.send_HTTP_OK(resp)
    end

    for i = 1, #projects do
        resp.projects[i] = {}
        resp.projects[i].description = projects[i].description
        resp.projects[i].domain_id = projects[i].domain_id
        resp.projects[i].enabled = projects[i].enabled
        resp.projects[i].id = projects[i].id
        resp.projects[i].name = projects[i].name
        resp.projects[i].parent_id = projects[i].parent_id
        resp.projects[i].links = {
            self = resp.links.self..'/'..resp.projects[i].id
        }
        resp.projects[i].tags, err = dao_factory.project_tag:find_all({project_id = resp.projects[i].id})
        if err then
            if not resp.errors then
                resp.errors = {num = 0}
            end
            resp.errors.num = resp.errors.num + 1
            resp.errors[resp.errors.num] = {
                error = err,
                func = "dao_factory.project_tag:find_all"
            }
        end

    end

    return responses.send_HTTP_OK(resp)

end

local function create_project(self, dao_factory)
--    if true then
--        return responses.send_HTTP_BAD_REQUEST({params = self.params, request = self.req}) end -- TODO why self.params.domain not null?

    --ngx.req.read_body()
    --local request = ngx.req.get_body_data()
    --request = cjson.decode(request)
    local request = self.params
    if not request.project then
         return responses.send_HTTP_BAD_REQUEST("Project is nil, check self.params")
    end
    --print(request)
    local name = request.project.name -- must be checked that name is unique
    if not name then
        return responses.send_HTTP_BAD_REQUEST("Error: project name must be in the request")
    end

    local res, err = dao_factory.project:find_all({name=name})
    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.project:find_all"})
    end

    if next(res) then
        return responses.send_HTTP_BAD_REQUEST("Error: project with this name exists")
    end

    local is_domain = kstn_utils.bool(request.project.is_domain) or false
    local description = request.project.description or ''
    local domain_id = request.project.domain_id or kstn_utils.default_domain(dao_factory) --must be supplemented
    local enabled = kstn_utils.bool(request.project.enabled) or true
    local parent_id = request.project.parent_id --must be supplemented
    local id = utils.uuid()

    local project_obj = {
        id = id,
        name = name,
        description = description,
        enabled = enabled,
        domain_id = domain_id,
        parent_id = parent_id,
        is_domain = is_domain
    }

    local res, err = dao_factory.project:insert(project_obj)

    if err then
            return responses.send_HTTP_CONFLICT({error = err, object = project_obj})
    end

    project_obj.links = {
                self = self:build_url(self.req.parsed_url.path)
            }

    local response = {project = project_obj}
    return responses.send_HTTP_CREATED(response)
end

local function get_project_info(self, dao_factory)
    local project_id = self.params.project_id
    if not project_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad project id")
    end

    local project, err = dao_factory.project:find({id=project_id})
    if err then
        return responses.send_HTTP_NOT_FOUND("Error: bad project id")
    end

    local project_obj = {
        is_domain = project.is_domain,
        description = project.description,
        domain_id = project.domain_id,
        enabled = project.enabled,
        id = project.id,
        links = {self = self:build_url(self.req.parsed_url.path)},
        name = project.name,
        parent_id = project.parent_id
    }

    --ngx.req.read_body()
    --local request = ngx.req.get_body_data()
    --request = cjson.decode(request)
    local request = self.params

    if request then
        if request.parents_as_list then
            parents = {}
            local cur_project = project_obj
            while true do
                if not cur_project.parent_id then
                    break
                end

                local parent, err = dao_factory.project:find({id=cur_project.parent_id})
                if not parent then
                    break
                end

                parent.links = {self = self:build_url(self.req.parsed_url.path)}
                table.insert(parents, parent)
                cur_project = parent
            end
            project_obj.parents = parents
        end

        if request.subtree_as_list then
            get_subtree_as_list(self, dao_factory, project_obj)
            project_obj.subtree = subtree
        end

        if request.parents_as_ids then
            parent_ids = {}
            local cur_project = project_obj
            while true do
                if not cur_project.parent_id then
                    break
                end

                local parent, err = dao_factory.project:find({id=cur_project.parent_id})
                if not parent then
                    break
                end

                table.insert(parents, parent.id)
                cur_project = parent
            end
            project_obj.parent_ids = parent_ids
        end

        if request.subtree_as_ids then
            get_subtree_as_ids()
            project_obj.subtree_ids = subtrtee_as_ids
        end
    end

    local response = {project = project_obj}
    return responses.send_HTTP_OK(response)
end

local function update_project(self, dao_factory)
    local project_id = self.params.project_id
    if not project_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad project id")
    end

    local project, err = dao_factory.project:find({id=project_id})
    if not project then
        return responses.send_HTTP_NOT_FOUND("Error: bad project id")
    end

--    ngx.req.read_body()
--    local request = ngx.req.get_body_data()
--    request = cjson.decode(request)
    local request = self.params
    if not request.project then
         return responses.send_HTTP_BAD_REQUEST("Project is nil, check self.params")
    end

    local updated_project, err = dao_factory.project:update(request.project, {id=project.id})
    if err then
        return responses.send_HTTP_BAD_REQUEST(err)
    end

    local response = {project = updated_project}
    return responses.send_HTTP_OK(response)
end

local function delete_project(self, dao_factory)
    local project_id = self.params.project_id
    if not project_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad project id")
    end

    local _, err = dao_factory.project:find({id=project_id})
    if err then
        return responses.send_HTTP_NOT_FOUND("Error: bad project id")
    end

    local _, err = dao_factory.project:delete({id = project_id})

    if err then
        return responses.send_HTTP_NOT_FOUND(err)
    end

    return responses.send_HTTP_NO_CONTENT()
end

Project.list_projects = list_projects
Project.create_project = create_project
Project.get_project_info = get_project_info
Project.update_project = update_project
Project.delete_project = delete_project

return {
    ["/v3/projects"] = {
        GET = function(self, dao_factory)
            Project.list_projects(self, dao_factory)
        end,
        POST = function(self, dao_factory)
            Project.create_project(self, dao_factory)
        end
    },
    ["/v3/projects/:project_id"] = {
        GET = function(self, dao_factory)
            Project.get_project_info(self, dao_factory)
        end,
        PATCH = function(self, dao_factory)
            Project.update_project(self, dao_factory)
        end,
        DELETE = function(self, dao_factory)
            Project.delete_project(self, dao_factory)
        end
    }
}
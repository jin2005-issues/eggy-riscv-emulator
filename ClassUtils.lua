local ClassUtils = {}

function ClassUtils.class(classname, super)
	local superType = type(super)
	assert(super == nil or type(super) == "table", superType)

	local cls
	if super then
		cls = {}
		setmetatable(cls, {__index = super})
		cls.super = super
	else
		cls = {}
	end

	cls.__cname = classname
	cls.__index = cls

	function cls.new(...)
		local instance = setmetatable({}, cls)

		local child = cls
		local classes = {cls}
		while child.super do
			table.insert(classes, child.super)
			child = child.super
		end

		for i=#classes,1,-1 do
			local ctor = rawget(classes[i], "ctor")
			if ctor then
				ctor(instance, ...)
			end
		end

		return instance
	end

	return cls
end

return ClassUtils
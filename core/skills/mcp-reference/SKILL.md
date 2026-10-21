---
name: mcp-reference
description: Use when building or configuring MCP servers, skills or agents - tool, skill and agent conventions and reference.
---

# MCP Tools, Skills & Agents Reference

## Auto-Discovery Protocol

### Discovering Available Tools

When you need MCP capabilities, list the MCP tools in the current tool listing (deferred tools can
be loaded by name with ToolSearch) rather than relying on a static list.

### Discovering Available Skills

Skills are listed in the Skill tool's `<available_skills>` section. To discover skills:

1. Check the Skill tool description for `<available_skills>` block
2. Skills are invoked via: `Skill(skill="<skill-name>")`

### Discovering Available Agents (Task Tool)

Agents are specialized subprocesses invoked via the Task tool. The available agents are listed in the Task tool description under agent types.

## Usage Patterns

### Pattern 1: Direct Skill Invocation
```
# When you know which skill to use
Skill(skill="<a skill from the available_skills list>")
```

### Pattern 2: Agent Delegation
```
# Delegate complex tasks to specialized agents
Task(
  subagent_type="<an agent type from the Task tool listing>",
  prompt="Optimize this function for performance: [code]"
)
```

### Pattern 3: MCP Tool Discovery
```
# Discover MCP tools for a specific task: search the tool listing / ToolSearch
# for keywords from the task description
```

### Pattern 4: Parallel Agent Execution
```
# Launch multiple agents in parallel for independent tasks
# (Use single message with multiple Task tool calls)
```

## Skill Selection Guidelines

### When to Use Skills
- **Domain-specific workflows**: Use a skill that matches the domain, such as `core:react-standards` for React/TypeScript patterns
- **Tool-specific operations**: Use the skill written for that tool, when one is listed
- **Process guidance**: Use `core:code-review-standards` for systematic review workflows

### When to Use Agents
- **Complex autonomous tasks**: Agents can explore, plan, and execute
- **Specialized expertise**: Agents have deep domain knowledge
- **Multi-step operations**: Agents maintain context across steps

### When to Use MCP Tools Directly
- **Simple operations**: Direct tool calls for straightforward tasks
- **Specific integrations**: When you know exactly which MCP tool to use

## Discovery Best Practices

1. **Check before assuming**: Don't assume a tool/skill/agent exists; verify in tool descriptions
2. **Use appropriate granularity**: Skills for workflows, agents for complex tasks, tools for operations
3. **Leverage parallelism**: Independent agent tasks can run concurrently
4. **Match tool to task**: Use the most specific tool available for the job

## MCP Query Pagination

When querying MCP tools that return lists, follow pagination protocol:

```python
# Probe with small limit
probe = mcp_call(limit=5)
tokens_per_item = estimate_tokens(probe) / 5

# Calculate safe limit (stay under 20k tokens)
safe_limit = min(15000 / tokens_per_item, 50)

# Paginate if needed (max 5 batches)
results = []
for i in range(5):
    batch = mcp_call(limit=safe_limit, offset=i * safe_limit)
    if estimate_tokens(batch) > 20000:
        break
    results.extend(batch)
```

## Refreshing This Reference

MCP tools, skills, and agents can change as configurations update. To get current availability:

1. **Tools**: Check MCP server configurations in `~/.claude/` or project `.claude/`
2. **Skills**: Refer to Skill tool's `<available_skills>` section
3. **Agents**: Refer to Task tool's agent type list

When uncertain about capability availability, use discovery commands rather than assuming from this reference.

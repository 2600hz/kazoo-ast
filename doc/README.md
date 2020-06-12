# Kazoo AST

This library is for parsing the Erlang AST (Abstract Syntax Tree) of various Kazoo Erlang modules, looking to automatically pull out information for use by developers or users of Kazoo.

## Existing AST modules

### cb\_api\_endpoints

This module primarily looks for what endpoint paths are exposed by each Crossbar endpoint module. This is done by parsing each module's \`allowed\_methods\` exported functions and using the function's arguments and the returned list of HTTP verbs.

Additionally, this module can take a JSON schema (using the module's name to determine the schema file name) and create a Markdown table.

This functionality is utilized in the \`to\_ref\_doc/0\` and \`to\_swagger\_file/0\` to create [reference documentation files](https://github.com/2600hz/kazoo/tree/master/applications/crossbar/doc/ref) for each Crossbar endpoint and to populate/update a [swagger.json](https://github.com/2600hz/kazoo/blob/master/applications/crossbar/priv/couchdb/swagger/swagger.json) file. The ref docs are then used as guides in creating/updating the [Crossbar documentation](https://github.com/2600hz/kazoo/tree/master/applications/crossbar/doc).

The next step is to create an escript that will, on each PR, run the \`to\_ref\_doc/0\`; if there are changes to the ref doc files, there will be unstaged changes that should trigger the committer to fold those into the docs. These unstaged changes can also be detected in CI and fail the build so that committers will be alerted.

### cf\_data\_usage

This module looks for callflow action modules and traces the usage of \`Data\` in the \`handle/2\` exported function. It then looks for where the call paths get values out of the \`Data\` JSON object. Once collected, the module attempts to create/update a [\`callflows.{ACTION}.json\`](https://github.com/2600hz/kazoo/tree/184b16fe5ae9dd7481f70d1bcff5f21b6510f70b/applications/crossbar/priv/couchdb/schemas) JSON schema document. The module inserts the keys found, tries to guess the type permitted, and includes the default if applicable.

This functionality is utilized in the \`to\_schema\_docs/0\` (to process all callflow actions - that is, modules that implement the gen\_cf\_action Erlang behaviour) and the \`to\_schema\_doc/1\`, which takes the callflow action's module name (eg cf\_park, cf\_user, cf\_voicemail, etc).

Similar to \`cb\_api\_endpoints\`, the next step is to make this an escript that runs on each build, creates unstaged changes, and forces a committer to address the detected changes.

### kapps\_config\_usage

This module looks in all Kazoo Erlang application modules for calls to kapps\_config (docs in the \`system\_config\` database) getters. Similar to \`cf\_data\_usage\`, \`kapps\_config\_usage\` will create schemas if missing, update existing schemas, guess types, and include defaults if appropriate.

It also builds schemas for account config documents (account-overrides of system\_config parameters).

### code\_usage

This module looks across the project for function call usage. It counts M:F/A and M:F(Args) instances (counting the length of Args to get arity) in the AST. The printer then takes an optional argument to print the Top hits.

    `code_usage:tabulate()`: print the top 25 M:F/A across the project
    `code_usage:tabulate(50)`: print the top 50 M:F/A across the project
    `code_usage:tabulate(crossbar)`: print the top 25 M:F/A in Crossbar
    `code_usage:tabulate(crossbar, 50)`: print the top 50 M:F/A in Crossbar

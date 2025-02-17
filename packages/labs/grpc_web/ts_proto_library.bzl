# Copyright 2020 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"Protocol Buffers"

load("@build_bazel_rules_nodejs//:providers.bzl", "DeclarationInfo", "JSEcmaScriptModuleInfo", "JSModuleInfo", "JSNamedModuleInfo")
load("@rules_proto//proto:defs.bzl", "ProtoInfo")

typescript_proto_library_aspect = provider(
    fields = {
        "deps_dts": "The transitive dependencies' TS definitions",
        "deps_es5": "The transitive ES5 JS dependencies",
        "deps_es6": "The transitive ES6 JS dependencies",
        "dts_outputs": "Ths TS definition files produced directly from the src protos",
        "es5_outputs": "The ES5 JS files produced directly from the src protos",
        "es6_outputs": "The ES6 JS files produced directly from the src protos",
    },
)

# TODO(dan): Replace with |proto_common.direct_source_infos| when
# https://github.com/bazelbuild/rules_proto/pull/22 lands.
# Derived from https://github.com/grpc-ecosystem/grpc-gateway/blob/e8db07a3923d3f5c77dbcea96656afe43a2757a8/protoc-gen-swagger/defs.bzl#L11
def _direct_source_infos(proto_info, provided_sources = []):
    """Returns sequence of `ProtoFileInfo` for `proto_info`'s direct sources.
    Files that are both in `proto_info`'s direct sources and in
    `provided_sources` are skipped. This is useful, e.g., for well-known
    protos that are already provided by the Protobuf runtime.
    Args:
      proto_info: An instance of `ProtoInfo`.
      provided_sources: Optional. A sequence of files to ignore.
          Usually, these files are already provided by the
          Protocol Buffer runtime (e.g. Well-Known protos).
    Returns: A sequence of `ProtoFileInfo` containing information about
        `proto_info`'s direct sources.
    """

    source_root = proto_info.proto_source_root
    if "." == source_root:
        return [struct(file = src, import_path = src.path) for src in proto_info.direct_sources]

    offset = len(source_root) + 1  # + '/'.

    infos = []
    for src in proto_info.direct_sources:
        infos.append(struct(file = src, import_path = src.path[offset:]))

    return infos

def _get_protoc_inputs(target, ctx):
    inputs = []
    inputs += target[ProtoInfo].direct_sources
    inputs += target[ProtoInfo].transitive_descriptor_sets.to_list()
    return inputs

def _build_protoc_command(target, ctx):
    protoc_command = "%s" % (ctx.executable._protoc.path)

    protoc_command += " --plugin=protoc-gen-grpc-web=%s" % (ctx.executable._protoc_gen_grpc_web.path)

    protoc_output_dir = ctx.var["BINDIR"]
    protoc_command += " --grpc-web_out=import_style=commonjs+dts,mode=grpcweb:%s" % (protoc_output_dir)
    protoc_command += " --js_out=import_style=commonjs:%s" % (protoc_output_dir)

    descriptor_sets_paths = [desc.path for desc in target[ProtoInfo].transitive_descriptor_sets.to_list()]

    pathsep = ctx.configuration.host_path_separator
    protoc_command += " --descriptor_set_in=\"%s\"" % (pathsep.join(descriptor_sets_paths))

    proto_file_infos = _direct_source_infos(target[ProtoInfo])
    for f in proto_file_infos:
        protoc_command += " %s" % f.import_path

    return protoc_command

def _create_post_process_command(target, ctx, protoc_outputs, js_outputs, js_outputs_es6):
    """
    Builds a post-processing command that:
      - Updates the existing protoc output files to be UMD modules
      - Creates a new es6 file from the original protoc output
    """
    convert_commands = []
    for [input_, output, output_es6] in zip(protoc_outputs, js_outputs, js_outputs_es6):
        input_path = "/".join([ctx.var["BINDIR"], input_])
        file_path = "/".join([p for p in [
            ctx.workspace_name,
            ctx.label.package,
        ] if p])
        file_name = output.basename[:-len(output.extension) - 1]

        convert_command = ctx.executable._change_import_style.path
        convert_command += " --workspace_name={}".format(ctx.workspace_name)
        convert_command += " --input_base_path={}".format(file_path)
        convert_command += " --output_module_name={}".format(file_name)
        convert_command += " --input_file_path={}".format(input_path)
        convert_command += " --output_umd_path={}".format(output.path)
        convert_command += " --output_es6_path={}".format(output_es6.path)
        convert_commands.append(convert_command)

    return " && ".join(convert_commands)

def _get_outputs(target, ctx):
    """
    Calculates all of the files that will be generated by the aspect.
    """
    protoc_outputs = []
    js_outputs = []
    js_outputs_es6 = []
    dts_outputs = []
    for src in _direct_source_infos(target[ProtoInfo]):
        file_name = src.file.basename[:-len(src.file.extension) - 1]
        protoc_path_base = src.import_path[:-len(src.file.extension) - 1]
        generated_files = ["_pb", "_grpc_web_pb"]
        for f in generated_files:
            full_name = file_name + f
            protoc_output = protoc_path_base + f + ".js"
            protoc_outputs.append(protoc_output)
            output = ctx.actions.declare_file(full_name + ".js")
            js_outputs.append(output)
            output_es6 = ctx.actions.declare_file(full_name + ".mjs")
            js_outputs_es6.append(output_es6)
            output_d_ts = ctx.actions.declare_file(file_name + f + ".d.ts")
            dts_outputs.append(output_d_ts)

    return [protoc_outputs, js_outputs, js_outputs_es6, dts_outputs]

def ts_proto_library_aspect_(target, ctx):
    """
    A bazel aspect that is applied on every proto_library rule on the transitive set of dependencies
    of a ts_proto_library rule.

    Handles running protoc to produce the generated JS and TS files.
    """

    [protoc_outputs, js_outputs, js_outputs_es6, dts_outputs] = _get_outputs(target, ctx)
    final_outputs = dts_outputs + js_outputs + js_outputs_es6

    all_commands = [
        _build_protoc_command(target, ctx),
        _create_post_process_command(target, ctx, protoc_outputs, js_outputs, js_outputs_es6),
    ]

    tools = []
    tools.extend(ctx.files._protoc)
    tools.extend(ctx.files._protoc_gen_grpc_web)
    tools.extend(ctx.files._change_import_style)

    ctx.actions.run_shell(
        inputs = depset(
            direct = _get_protoc_inputs(target, ctx),
            transitive = [depset(ctx.files._well_known_protos)],
        ),
        outputs = final_outputs,
        progress_message = "Creating Typescript pb files %s" % ctx.label,
        command = " && ".join(all_commands),
        tools = depset(tools),
    )

    dts_outputs = depset(dts_outputs)
    es5_outputs = depset(js_outputs)
    es6_outputs = depset(js_outputs_es6)
    deps_dts = []
    deps_es5 = []
    deps_es6 = []

    for dep in ctx.rule.attr.deps:
        aspect_data = dep[typescript_proto_library_aspect]
        deps_dts.append(aspect_data.dts_outputs)
        deps_dts.append(aspect_data.deps_dts)
        deps_es5.append(aspect_data.es5_outputs)
        deps_es5.append(aspect_data.deps_es5)
        deps_es6.append(aspect_data.es6_outputs)
        deps_es6.append(aspect_data.deps_es6)

    return [typescript_proto_library_aspect(
        dts_outputs = dts_outputs,
        es5_outputs = es5_outputs,
        es6_outputs = es6_outputs,
        deps_dts = depset(transitive = deps_dts),
        deps_es5 = depset(transitive = deps_es5),
        deps_es6 = depset(transitive = deps_es6),
    )]

ts_proto_library_aspect = aspect(
    implementation = ts_proto_library_aspect_,
    attr_aspects = ["deps"],
    attrs = {
        "_change_import_style": attr.label(
            executable = True,
            cfg = "host",
            allow_files = True,
            default = Label("//packages/labs/grpc_web:change_import_style"),
        ),
        "_protoc": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "host",
            default = Label("@com_google_protobuf//:protoc"),
        ),
        "_protoc_gen_grpc_web": attr.label(
            allow_files = True,
            executable = True,
            cfg = "host",
            default = Label("@com_github_grpc_grpc_web//javascript/net/grpc/web:protoc-gen-grpc-web"),
        ),
        "_well_known_protos": attr.label(
            default = "@com_google_protobuf//:well_known_protos",
            allow_files = True,
        ),
    },
)

def _ts_proto_library_impl(ctx):
    """
    Handles converting the aspect output into a provider compatible with the rules_typescript rules.
    """
    aspect_data = ctx.attr.proto[typescript_proto_library_aspect]
    dts_outputs = aspect_data.dts_outputs
    transitive_declarations = depset(transitive = [dts_outputs, aspect_data.deps_dts])
    es5_outputs = aspect_data.es5_outputs
    es6_outputs = aspect_data.es6_outputs
    outputs = depset(transitive = [es5_outputs, es6_outputs, dts_outputs])

    es5_srcs = depset(transitive = [es5_outputs, aspect_data.deps_es5])
    es6_srcs = depset(transitive = [es6_outputs, aspect_data.deps_es6])
    return struct(
        typescript = struct(
            declarations = dts_outputs,
            transitive_declarations = transitive_declarations,
            es5_sources = es5_srcs,
            es6_sources = es6_srcs,
            transitive_es5_sources = es5_srcs,
            transitive_es6_sources = es6_srcs,
        ),
        providers = [
            DefaultInfo(files = outputs),
            DeclarationInfo(
                declarations = dts_outputs,
                transitive_declarations = transitive_declarations,
                type_blacklisted_declarations = depset([]),
            ),
            JSModuleInfo(
                direct_sources = es5_srcs,
                sources = es5_srcs,
            ),
            JSNamedModuleInfo(
                direct_sources = es5_srcs,
                sources = es5_srcs,
            ),
            JSEcmaScriptModuleInfo(
                direct_sources = es6_srcs,
                sources = es6_srcs,
            ),
        ],
    )

ts_proto_library = rule(
    attrs = {
        "proto": attr.label(
            allow_single_file = True,
            aspects = [ts_proto_library_aspect],
            mandatory = True,
            providers = [ProtoInfo],
        ),
        "_protoc": attr.label(
            allow_single_file = True,
            cfg = "host",
            default = Label("@com_google_protobuf//:protoc"),
            executable = True,
        ),
        "_protoc_gen_grpc_web": attr.label(
            allow_files = True,
            cfg = "host",
            default = Label("@com_github_grpc_grpc_web//javascript/net/grpc/web:protoc-gen-grpc-web"),
            executable = True,
        ),
        "_well_known_protos": attr.label(
            allow_files = True,
            default = "@com_google_protobuf//:well_known_protos",
        ),
    },
    implementation = _ts_proto_library_impl,
)

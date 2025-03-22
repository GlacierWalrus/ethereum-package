shared_utils = import_module("../../shared_utils/shared_utils.star")
input_parser = import_module("../../package_io/input_parser.star")
el_context = import_module("../../el/el_context.star")
el_admin_node_info = import_module("../../el/el_admin_node_info.star")
el_shared = import_module("../el_shared.star")
node_metrics = import_module("../../node_metrics_info.star")
constants = import_module("../../package_io/constants.star")

# The dirpath of the execution data directory on the client container
EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER = "/data/besu/execution-data"

METRICS_PATH = "/metrics"

RPC_PORT_NUM = 8545
WS_PORT_NUM = 8546
DISCOVERY_PORT_NUM = 30303
ENGINE_HTTP_RPC_PORT_NUM = 8551
METRICS_PORT_NUM = 9001

JAVA_OPTS = {"JAVA_OPTS": "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n"}

ENTRYPOINT_ARGS = ["sh", "-c"]

VERBOSITY_LEVELS = {
    constants.GLOBAL_LOG_LEVEL.error: "ERROR",
    constants.GLOBAL_LOG_LEVEL.warn: "WARN",
    constants.GLOBAL_LOG_LEVEL.info: "INFO",
    constants.GLOBAL_LOG_LEVEL.debug: "DEBUG",
    constants.GLOBAL_LOG_LEVEL.trace: "TRACE",
}


def launch(
    plan,
    launcher,
    service_name,
    participant,
    global_log_level,
    existing_el_clients,
    persistent,
    tolerations,
    node_selectors,
    port_publisher,
    participant_index,
    kubernetes_config,
):
    log_level = input_parser.get_client_log_level_or_default(
        participant.el_log_level, global_log_level, VERBOSITY_LEVELS
    )

    cl_client_name = service_name.split("-")[3]

    config = get_config(
        plan,
        launcher,
        participant,
        service_name,
        existing_el_clients,
        cl_client_name,
        log_level,
        persistent,
        tolerations,
        node_selectors,
        ingress_class_name,
        ingress_annotations,
        port_publisher,
        participant_index,
    )

    service = plan.add_service(service_name, config)

    enode = el_admin_node_info.get_enode_for_node(
        plan, service_name, constants.RPC_PORT_ID
    )

    metrics_url = "{0}:{1}".format(service.ip_address, METRICS_PORT_NUM)
    besu_metrics_info = node_metrics.new_node_metrics_info(
        service_name, METRICS_PATH, metrics_url
    )
    http_url = "http://{0}:{1}".format(service.ip_address, RPC_PORT_NUM)
    ws_url = "ws://{0}:{1}".format(service.ip_address, WS_PORT_NUM)

    return el_context.new_el_context(
        client_name="besu",
        enode=enode,
        ip_addr=service.ip_address,
        rpc_port_num=RPC_PORT_NUM,
        ws_port_num=WS_PORT_NUM,
        engine_rpc_port_num=ENGINE_HTTP_RPC_PORT_NUM,
        rpc_http_url=http_url,
        ws_url=ws_url,
        service_name=service_name,
        el_metrics_info=[besu_metrics_info],
    )


def get_config(
    plan,
    launcher,
    participant,
    service_name,
    existing_el_clients,
    cl_client_name,
    log_level,
    persistent,
    tolerations,
    node_selectors,
    port_publisher,
    participant_index,
    kubernetes_config,
):
    # Get kubernetes configuration
    kubernetes_config = input_parser.get_kubernetes_config(kubernetes_config)

    public_ports = {}
    discovery_port = DISCOVERY_PORT_NUM
    if port_publisher.el_enabled:
        public_ports_for_component = shared_utils.get_public_ports_for_component(
            "el", port_publisher, participant_index
        )
        public_ports, discovery_port = el_shared.get_general_el_public_port_specs(
            public_ports_for_component
        )
        additional_public_port_assignments = {
            constants.RPC_PORT_ID: public_ports_for_component[2],
            constants.WS_PORT_ID: public_ports_for_component[3],
            constants.METRICS_PORT_ID: public_ports_for_component[4],
        }
        public_ports.update(
            shared_utils.get_port_specs(additional_public_port_assignments)
        )

    used_port_assignments = {
        constants.TCP_DISCOVERY_PORT_ID: discovery_port,
        constants.UDP_DISCOVERY_PORT_ID: discovery_port,
        constants.ENGINE_RPC_PORT_ID: ENGINE_HTTP_RPC_PORT_NUM,
        constants.RPC_PORT_ID: RPC_PORT_NUM,
        constants.WS_PORT_ID: WS_PORT_NUM,
        constants.METRICS_PORT_ID: METRICS_PORT_NUM,
    }
    used_ports = shared_utils.get_port_specs(used_port_assignments)

    cmd = [
        "besu",
        "--logging=" + log_level,
        "--data-path=" + EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER,
        "--genesis-file=" + constants.GENESIS_CONFIG_MOUNT_PATH_ON_CONTAINER + "/genesis.json",
        "--rpc-http-enabled=true",
        "--rpc-http-host=0.0.0.0",
        "--rpc-http-port={0}".format(RPC_PORT_NUM),
        "--rpc-http-cors-origins=*",
        "--rpc-ws-enabled=true",
        "--rpc-ws-host=0.0.0.0",
        "--rpc-ws-port={0}".format(WS_PORT_NUM),
        "--host-allowlist=*",
        "--engine-rpc-enabled=true",
        "--engine-host-allowlist=*",
        "--engine-jwt-secret=" + constants.JWT_MOUNT_PATH_ON_CONTAINER,
        "--engine-rpc-port={0}".format(ENGINE_HTTP_RPC_PORT_NUM),
        "--p2p-enabled=true",
        "--p2p-host={0}".format(port_publisher.nat_exit_ip),
        "--p2p-port={0}".format(discovery_port),
        "--metrics-enabled",
        "--metrics-host=0.0.0.0",
        "--metrics-port={0}".format(METRICS_PORT_NUM),
        "--sync-mode=FULL",
        "--rpc-http-api=ADMIN,DEBUG,ETH,NET,WEB3,TXPOOL",
        "--rpc-ws-api=ADMIN,DEBUG,ETH,NET,WEB3,TXPOOL",
    ]

    return ServiceConfig(
        image=participant.el_image,
        ports=used_ports,
        public_ports=public_ports,
        cmd=cmd + participant.el_extra_params,
        files={
            constants.GENESIS_CONFIG_MOUNT_PATH_ON_CONTAINER: launcher.genesis_config,
            constants.JWT_MOUNT_PATH_ON_CONTAINER: launcher.jwt_secret,
        },
        entrypoint=ENTRYPOINT_ARGS,
        ready_conditions=el_shared.get_el_ready_conditions(
            constants.RPC_PORT_ID, constants.ENGINE_RPC_PORT_ID
        ),
        private_ip_address_placeholder=constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        min_cpu=participant.el_min_cpu,
        max_cpu=participant.el_max_cpu,
        min_memory=participant.el_min_mem,
        max_memory=participant.el_max_mem,
        env_vars=participant.el_extra_env_vars,
        labels=participant.el_extra_labels,
        node_selectors=node_selectors,
        tolerations=tolerations,
        kubernetes_config=kubernetes_config,
    )


def new_besu_launcher(el_cl_genesis_data, jwt_file, network):
    return struct(
        el_cl_genesis_data=el_cl_genesis_data,
        jwt_file=jwt_file,
        network=network,
    )

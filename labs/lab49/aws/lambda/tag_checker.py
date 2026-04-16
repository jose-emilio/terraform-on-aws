import json
import logging
from datetime import datetime, timezone
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

config_client = boto3.client('config')
ec2_client    = boto3.client('ec2')


def evaluate_instance(instance_id, tags):
    has_cost_center = 'CostCenter' in tags
    compliance = 'COMPLIANT' if has_cost_center else 'NON_COMPLIANT'
    logger.info(
        "Instancia %s → %s (tags presentes: %s)",
        instance_id, compliance,
        list(tags.keys()) if tags else "ninguna"
    )
    return compliance


def put_and_check(evaluations, result_token):
    """Llama a put_evaluations y registra cualquier evaluación rechazada.

    put_evaluations tiene dos modos de fallo:
    1. Excepción boto3: error de red, credenciales o permisos IAM insuficientes.
       Se relanza para que Lambda marque la invocación como Error en CloudWatch.
    2. FailedEvaluations en la respuesta: Config rechaza evaluaciones específicas
       (token caducado, recurso fuera de scope) sin lanzar excepción.
       Se registra como error pero no se relanza.
    """
    try:
        response = config_client.put_evaluations(
            Evaluations=evaluations,
            ResultToken=result_token
        )
    except Exception as e:
        logger.error("put_evaluations lanzó excepción (permisos IAM?): %s", str(e))
        raise

    failed = response.get('FailedEvaluations', [])
    if failed:
        logger.error("Config rechazó %d evaluaciones: %s", len(failed), failed)
    else:
        for ev in evaluations:
            logger.info(
                "Evaluación aceptada: %s → %s",
                ev['ComplianceResourceId'], ev['ComplianceType']
            )


def handle_configuration_change(event):
    invoking_event = json.loads(event['invokingEvent'])
    config_item = invoking_event.get('configurationItem', {})

    resource_type = config_item.get('resourceType', 'UNKNOWN')
    resource_id   = config_item.get('resourceId', 'UNKNOWN')

    logger.info("ConfigurationChange: type=%s id=%s", resource_type, resource_id)

    if resource_type != 'AWS::EC2::Instance':
        logger.info("Tipo ignorado: %s", resource_type)
        return

    tags = config_item.get('tags', {})
    compliance = evaluate_instance(resource_id, tags)

    put_and_check(
        evaluations=[{
            'ComplianceResourceType': resource_type,
            'ComplianceResourceId':   resource_id,
            'ComplianceType':          compliance,
            'OrderingTimestamp':       config_item['configurationItemCaptureTime']
        }],
        result_token=event['resultToken']
    )


def handle_scheduled(event):
    logger.info("ScheduledNotification: evaluando todas las instancias EC2")
    now = datetime.now(timezone.utc).isoformat()
    evaluations = []

    paginator = ec2_client.get_paginator('describe_instances')
    for page in paginator.paginate():
        for reservation in page['Reservations']:
            for instance in reservation['Instances']:
                instance_id = instance['InstanceId']
                tags = {t['Key']: t['Value'] for t in instance.get('Tags', [])}
                compliance = evaluate_instance(instance_id, tags)
                evaluations.append({
                    'ComplianceResourceType': 'AWS::EC2::Instance',
                    'ComplianceResourceId':   instance_id,
                    'ComplianceType':          compliance,
                    'OrderingTimestamp':       now
                })

    for i in range(0, len(evaluations), 100):
        put_and_check(evaluations[i:i+100], event['resultToken'])

    logger.info("Evaluadas %d instancias en modo scheduled", len(evaluations))


def lambda_handler(event, context):
    message_type = json.loads(event['invokingEvent']).get('messageType', '')

    if message_type == 'ConfigurationItemChangeNotification':
        handle_configuration_change(event)
    elif message_type == 'ScheduledNotification':
        handle_scheduled(event)
    else:
        logger.warning("Tipo de mensaje no soportado: %s", message_type)

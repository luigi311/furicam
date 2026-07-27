// SPDX-License-Identifier: GPL-2.0-only

#include "accelreader.h"
#include <QDBusConnection>
#include <QDBusReply>
#include <QDBusArgument>
#include <QDebug>
#include <cstdlib>

AccelReader::AccelReader(QObject *parent)
    : QObject(parent)
    , m_sensorIface(nullptr)
    , m_sessionId(1000 + (std::rand() % 9000))
{
    m_sensorIface = new QDBusInterface(
        "com.nokia.SensorService",
        "/SensorManager/accelerometersensor",
        "local.AccelerometerSensor",
        QDBusConnection::systemBus(),
        this
    );

    connect(&m_timer, &QTimer::timeout, this, &AccelReader::readSensor);
}

AccelReader::~AccelReader()
{
    if (m_active) {
        stopSensor();
    }
}

void AccelReader::setActive(bool active)
{
    if (m_active == active) return;
    m_active = active;

    if (active) {
        startSensor();
    } else {
        stopSensor();
    }

    emit activeChanged();
}

void AccelReader::startSensor()
{
    if (!m_sensorIface || !m_sensorIface->isValid()) {
        qDebug() << "AccelReader: sensorfw D-Bus interface not available";
        return;
    }

    m_sensorIface->asyncCall("start", m_sessionId);
    m_timer.start(33); // ~30 Hz
}

void AccelReader::stopSensor()
{
    m_timer.stop();

    if (m_sensorIface && m_sensorIface->isValid()) {
        m_sensorIface->asyncCall("stop", m_sessionId);
    }
}

void AccelReader::readSensor()
{
    if (!m_sensorIface || !m_sensorIface->isValid()) return;
    // Don't fire another request while one is in flight — a sluggish sensor
    // service would otherwise stack up blocking calls.
    if (m_pending)
        return;

    QDBusMessage msg = QDBusMessage::createMethodCall(
        "com.nokia.SensorService",
        "/SensorManager/accelerometersensor",
        "org.freedesktop.DBus.Properties",
        "Get"
    );
    msg << "local.AccelerometerSensor" << "xyz";

    m_pending = true;
    QDBusConnection::systemBus().callWithCallback(msg, this,
        SLOT(onSensorReply(QDBusMessage)),
        SLOT(onSensorError(QDBusError)));
}

void AccelReader::onSensorReply(const QDBusMessage &reply)
{
    m_pending = false;
    if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
        return;
    }

    // The reply is variant containing struct (tddd)
    QVariant outerVariant = reply.arguments().first();
    QDBusVariant dbusVariant = outerVariant.value<QDBusVariant>();
    QVariant innerVariant = dbusVariant.variant();
    const QDBusArgument arg = innerVariant.value<QDBusArgument>();

    quint64 timestamp;
    double x, y, z;

    arg.beginStructure();
    arg >> timestamp >> x >> y >> z;
    arg.endStructure();

    // Values are in milliG, convert to m/s² (divide by ~101.97) or just use raw
    // For atan2 the scale doesn't matter, so keep milliG
    if (x != m_x || y != m_y || z != m_z) {
        m_x = x;
        m_y = y;
        m_z = z;
        emit readingChanged();
    }
}

void AccelReader::onSensorError(const QDBusError &error)
{
    m_pending = false;
    Q_UNUSED(error);
}

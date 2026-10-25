package io.apkrun.guest.daemon.files

import android.os.ParcelFileDescriptor
import io.apkrun.guest.daemon.GuestFailure
import io.apkrun.guest.protocol.v1.ExportDecision
import io.apkrun.guest.protocol.v1.ExportFileOffered
import io.apkrun.guest.protocol.v1.ExportStart
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ResolveExport
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Publishes one offer on the negotiated Guest Agent control connection. */
internal fun interface ExportOfferPublisher {
    fun publish(offer: ExportFileOffered): Boolean
}

/** A seekable input stream offered by SaveToMacActivity while it waits for the host's decision. */
internal data class ExportFileSource(
    val descriptor: ParcelFileDescriptor,
    val name: String,
    val mimeType: String,
    val size: Long,
    val sourcePackage: String,
    val displayId: Int,
)

/** Sends one accepted export on the current Guest Agent bulk connection. */
internal fun interface ExportBulkSender {
    @Throws(IOException::class)
    fun send(
        transferId: Long,
        descriptor: ParcelFileDescriptor,
        name: String,
        mimeType: String,
        size: Long,
    )
}

internal enum class ExportOutcome {
    SAVED,
    DECLINED,
    FAILED,
}

/**
 * Coordinates guest-originated file offers with host ResolveExport decisions and bulk transfers.
 *
 * Offers are kept only in memory and expire if the activity is abandoned. The sender is captured
 * when the host accepts, so a later bulk reconnection cannot receive bytes from a stale approval.
 */
internal class ExportFileService(
    private val publishOffer: ExportOfferPublisher,
    private val scope: CoroutineScope,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val offerIdSource: AtomicLong = AtomicLong(1),
    private val transferIdSource: AtomicLong = AtomicLong(1),
    private val offerTimeoutMillis: Long = DEFAULT_OFFER_TIMEOUT_MILLIS,
) {
    private enum class State {
        OFFERED,
        ACCEPTED,
        TRANSFERRING,
    }

    private class Pending(
        val id: Long,
        val source: ExportFileSource,
        val expiresAtMillis: Long,
        var state: State = State.OFFERED,
        var transferId: Long? = null,
        var responseRequestId: Long? = null,
        var sender: ExportBulkSender? = null,
        val completed: CompletableFuture<ExportOutcome> = CompletableFuture(),
    )

    private val lock = Any()
    private val offers = LinkedHashMap<Long, Pending>()
    private val pendingResponses = HashMap<Long, Pending>()
    private val activeTransferIds = HashSet<Long>()
    private var bulkSender: ExportBulkSender? = null
    private var controlOwner: Any? = null

    /** Publishes one offer and waits for its accepted transfer or decline. */
    fun offerAndWait(source: ExportFileSource): ExportOutcome {
        if (!validSource(source)) {
            closeQuietly(source.descriptor)
            return ExportOutcome.FAILED
        }

        val pending: Pending
        synchronized(lock) {
            expireLocked()
            if (controlOwner == null || offers.size >= MAXIMUM_PENDING_OFFERS) {
                closeQuietly(source.descriptor)
                return ExportOutcome.FAILED
            }
            val offerId = allocateId(offerIdSource, offers.keys)
            pending =
                Pending(
                    id = offerId,
                    source = source,
                    expiresAtMillis = nowMillis() + offerTimeoutMillis,
                )
            offers[offerId] = pending
        }

        val event =
            ExportFileOffered.newBuilder()
                .setOfferId(pending.id)
                .setName(source.name)
                .setMimeType(source.mimeType)
                .setSize(source.size)
                .setSourcePackage(source.sourcePackage)
                .setDisplayId(source.displayId)
                .build()
        val published =
            try {
                publishOffer.publish(event)
            } catch (_: Exception) {
                false
            }
        if (!published) {
            cancel(pending.id, ExportOutcome.FAILED)
            return ExportOutcome.FAILED
        }

        while (true) {
            try {
                return pending.completed.get(offerTimeoutMillis, TimeUnit.MILLISECONDS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                cancel(pending.id, ExportOutcome.FAILED)
                return ExportOutcome.FAILED
            } catch (_: Exception) {
                val stillResolvingOrSending =
                    synchronized(lock) {
                        offers[pending.id] === pending && pending.state != State.OFFERED
                    }
                if (stillResolvingOrSending) continue
                cancel(pending.id, ExportOutcome.FAILED)
                return ExportOutcome.FAILED
            }
        }
    }

    /** Attaches the sender for the active authenticated bulk connection. */
    fun attachBulkSender(sender: ExportBulkSender) {
        synchronized(lock) {
            bulkSender = sender
        }
    }

    /** Detaches only the sender that is closing. */
    fun detachBulkSender(sender: ExportBulkSender) {
        synchronized(lock) {
            if (bulkSender === sender) {
                bulkSender = null
            }
            val failed = offers.values.filter { it.sender === sender }.toList()
            failed.forEach { finishLocked(it, ExportOutcome.FAILED) }
        }
    }

    /** Marks the event channel live for newly offered files. */
    fun controlConnected(owner: Any) {
        synchronized(lock) {
            if (controlOwner !== owner) {
                offers.values.toList().forEach { finishLocked(it, ExportOutcome.FAILED) }
                controlOwner = owner
            }
            expireLocked()
        }
    }

    /** Cancels offers tied to a control session that is closing. */
    fun controlDisconnected(owner: Any) {
        synchronized(lock) {
            if (controlOwner !== owner) return
            controlOwner = null
            offers.values.toList().forEach { finishLocked(it, ExportOutcome.FAILED) }
        }
    }

    /** Resolves an offer and reserves an agent-allocated odd transfer ID when accepted. */
    fun resolve(requestId: Long, request: ResolveExport): ExportStart {
        if (request.offerId <= 0L) {
            throw invalidOffer()
        }
        synchronized(lock) {
            expireLocked()
            val pending = offers[request.offerId] ?: throw notFound()
            if (pending.state != State.OFFERED) throw notFound()

            when (request.decision) {
                ExportDecision.EXPORT_DECISION_DECLINE -> {
                    finishLocked(pending, ExportOutcome.DECLINED)
                    return ExportStart.getDefaultInstance()
                }
                ExportDecision.EXPORT_DECISION_ACCEPT -> {
                    val sender = bulkSender ?: throw unavailable()
                    val transferId = allocateTransferId()
                    if (transferId <= 0L) throw unavailable()
                    activeTransferIds += transferId
                    pending.state = State.ACCEPTED
                    pending.transferId = transferId
                    pending.responseRequestId = requestId
                    pending.sender = sender
                    pendingResponses[requestId] = pending
                    return ExportStart.newBuilder().setTransferId(transferId).build()
                }
                ExportDecision.EXPORT_DECISION_UNSPECIFIED,
                ExportDecision.UNRECOGNIZED -> throw invalidOffer()
            }
        }
    }

    /** Starts a reserved stream only after its ExportStart response reached the host. */
    fun responseSent(requestId: Long) {
        val pending =
            synchronized(lock) {
                val transfer = pendingResponses.remove(requestId) ?: return
                if (offers[transfer.id] !== transfer || transfer.state != State.ACCEPTED) return
                transfer.state = State.TRANSFERRING
                transfer
            }
        val sender =
            pending.sender
                ?: run {
                    cancel(pending.id, ExportOutcome.FAILED)
                    return
                }
        val transferId =
            pending.transferId
                ?: run {
                    cancel(pending.id, ExportOutcome.FAILED)
                    return
                }
        scope.launch(Dispatchers.IO) {
            val outcome =
                try {
                    sender.send(
                        transferId,
                        pending.source.descriptor,
                        pending.source.name,
                        pending.source.mimeType,
                        pending.source.size,
                    )
                    ExportOutcome.SAVED
                } catch (_: Exception) {
                    ExportOutcome.FAILED
                }
            synchronized(lock) {
                finishLocked(pending, outcome)
            }
        }
    }

    /** Releases the source if the response could not be delivered. */
    fun responseFailed(requestId: Long) {
        synchronized(lock) {
            pendingResponses.remove(requestId)?.let { finishLocked(it, ExportOutcome.FAILED) }
        }
    }

    private fun cancel(offerId: Long, outcome: ExportOutcome) {
        synchronized(lock) {
            offers[offerId]?.let { finishLocked(it, outcome) }
        }
    }

    private fun expireLocked() {
        val now = nowMillis()
        offers.values
            .filter { it.expiresAtMillis <= now && it.state != State.TRANSFERRING }
            .toList()
            .forEach { finishLocked(it, ExportOutcome.FAILED) }
    }

    private fun finishLocked(pending: Pending, outcome: ExportOutcome) {
        if (offers.remove(pending.id) !== pending) return
        pending.responseRequestId?.let(pendingResponses::remove)
        pending.transferId?.let(activeTransferIds::remove)
        closeQuietly(pending.source.descriptor)
        pending.completed.complete(outcome)
    }

    private fun validSource(source: ExportFileSource): Boolean =
        source.size in 0L..MAXIMUM_FILE_BYTES &&
            source.name.isNotBlank() &&
            source.name.toByteArray(Charsets.UTF_8).size <= MAXIMUM_NAME_BYTES &&
            !source.name.any(Char::isISOControl) &&
            source.mimeType.isNotBlank() &&
            source.mimeType.toByteArray(Charsets.UTF_8).size <= MAXIMUM_MIME_TYPE_BYTES &&
            !source.mimeType.any(Char::isISOControl) &&
            source.sourcePackage.isNotBlank() &&
            source.sourcePackage.toByteArray(Charsets.UTF_8).size <= MAXIMUM_PACKAGE_BYTES &&
            source.displayId >= 0

    private fun allocateId(source: AtomicLong, inUse: Set<Long>): Long {
        repeat(MAXIMUM_ID_ATTEMPTS) {
            val id = source.getAndUpdate { current ->
                if (current >= Long.MAX_VALUE - 2) 1 else current + 1
            }
            if (id > 0 && id !in inUse) return id
        }
        throw unavailable()
    }

    private fun allocateTransferId(): Long {
        repeat(MAXIMUM_ID_ATTEMPTS) {
            val transferId = transferIdSource.getAndUpdate { current ->
                if (current >= Long.MAX_VALUE - 2) 1 else current + 2
            }
            if (transferId > 0 && transferId % 2L == 1L && transferId !in activeTransferIds) {
                return transferId
            }
        }
        throw unavailable()
    }

    private fun closeQuietly(descriptor: ParcelFileDescriptor) {
        runCatching { descriptor.close() }
    }

    private fun invalidOffer() =
        GuestFailure(
            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
            "the export decision is not valid",
        )

    private fun notFound() =
        GuestFailure(
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
            "the export offer is no longer available",
        )

    private fun unavailable() =
        GuestFailure(
            GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
            "the file transfer channel is unavailable",
        )

    private companion object {
        const val MAXIMUM_PENDING_OFFERS = 20
        const val MAXIMUM_FILE_BYTES = 2L * 1024L * 1024L * 1024L
        const val MAXIMUM_NAME_BYTES = 255
        const val MAXIMUM_MIME_TYPE_BYTES = 255
        const val MAXIMUM_PACKAGE_BYTES = 255
        const val MAXIMUM_ID_ATTEMPTS = 32
        const val DEFAULT_OFFER_TIMEOUT_MILLIS = 10 * 60 * 1000L
    }
}

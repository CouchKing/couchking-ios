package app.mediaboard

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import coil.load
import java.util.Locale

class EpisodeAdapter(
    private val episodes: List<Ck.Episode>,
    private val current: Ck.StreamCtx,
    private val onClick: (Ck.Episode) -> Unit,
) : RecyclerView.Adapter<EpisodeAdapter.VH>() {

    class VH(v: View) : RecyclerView.ViewHolder(v) {
        val label: TextView = v.findViewById(R.id.ep_label)
        val thumb: ImageView = v.findViewById(R.id.ep_thumb)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH =
        VH(LayoutInflater.from(parent.context).inflate(R.layout.item_episode, parent, false))

    override fun getItemCount() = episodes.size

    override fun onBindViewHolder(h: VH, pos: Int) {
        val ep = episodes[pos]
        val isCurrent = ep.season == current.season && ep.episode == current.episode
        val done = Store.isWatched(h.itemView.context, "${current.imdbId}:${ep.season}:${ep.episode}")
        h.label.text = String.format(Locale.US, "%s%sS%02dE%02d%s%s",
            if (isCurrent) "▶ " else "", if (done) "✓ " else "", ep.season, ep.episode,
            if (ep.name.isNotBlank()) "\n" + ep.name else "",
            if (!ep.aired) "\n(not aired)" else "")
        h.label.setTextColor(if (isCurrent) 0xFF9F86FF.toInt() else 0xFFFFFFFF.toInt())
        h.itemView.alpha = if (ep.aired) 1f else 0.4f
        val r = 8f * h.itemView.resources.displayMetrics.density
        val ctx = h.itemView.context
        // RenderEffect blur (API 31+); Fire OS is API <=30 so it also needs the software blur
        // baked in at load time, or the spoiler shield did nothing on a Firestick (AJ Sep 10).
        applyUnwatchedBlur(h.thumb, ctx, done)
        val softBlur = Store.blurUnwatched(ctx) && !done && android.os.Build.VERSION.SDK_INT < 31
        if (ep.thumb != null) h.thumb.load(ep.thumb) {
            crossfade(true)
            transformations(buildList {
                if (softBlur) add(BlurTransformation())          // blur first…
                add(coil.transform.RoundedCornersTransformation(r))  // …then round the corners
            })
        }
        else h.thumb.setImageDrawable(null)
        h.itemView.isFocusable = ep.aired
        h.itemView.setOnClickListener { if (ep.aired) onClick(ep) }
    }
}

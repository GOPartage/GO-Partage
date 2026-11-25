-- GO Partage — sécurisation du quota de réceptions
-- Règle : pour N réceptions confirmées, il faut au minimum max(N - 1, 0) dons confirmés.
-- La première demande reste autorisée avant toute réception. Une seule réception en attente
-- est permise à la fois (contrôle existant conservé dans create_card_transfer).

CREATE OR REPLACE FUNCTION public.my_donation_eligibility()
RETURNS TABLE(donations_confirmed bigint, receptions_confirmed bigint, donations_required bigint, can_request boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_donations bigint;
  v_receptions bigint;
  v_required bigint;
  v_active_request boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Connexion obligatoire.';
  END IF;

  SELECT
    count(*) FILTER (WHERE status = 'confirmed' AND donor_id = v_user),
    count(*) FILTER (WHERE status = 'confirmed' AND recipient_id = v_user)
  INTO v_donations, v_receptions
  FROM public.transfers
  WHERE donor_id = v_user OR recipient_id = v_user;

  SELECT EXISTS (
    SELECT 1
    FROM public.card_requests
    WHERE member_id = v_user AND status = 'active'
  ) INTO v_active_request;

  v_required := public.required_donations(v_receptions);

  RETURN QUERY
  SELECT
    v_donations,
    v_receptions,
    v_required,
    CASE
      WHEN v_receptions = 0 THEN NOT v_active_request
      ELSE v_donations >= v_required
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_card_transfer(p_offer_id uuid, p_request_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_donor uuid;
  v_recipient uuid;
  v_card uuid;
  v_offer_quantity integer;
  v_owned integer;
  v_tradable boolean;
  v_approved boolean;
  v_transfer_id uuid;
  v_donations bigint;
  v_receptions bigint;
  v_required bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Connexion obligatoire.';
  END IF;

  SELECT member_id, card_id, quantity
  INTO v_donor, v_card, v_offer_quantity
  FROM public.card_offers
  WHERE id = p_offer_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND OR v_offer_quantity < 1 THEN
    RAISE EXCEPTION 'Offre indisponible.';
  END IF;
  IF v_donor <> v_user THEN
    RAISE EXCEPTION 'Seul le donneur peut proposer cette offre.';
  END IF;

  SELECT member_id
  INTO v_recipient
  FROM public.card_requests
  WHERE id = p_request_id AND card_id = v_card AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Demande indisponible.';
  END IF;
  IF v_donor = v_recipient THEN
    RAISE EXCEPTION 'Tu ne peux pas te donner une carte.';
  END IF;

  -- Sérialise les réceptions d'un même bénéficiaire pour empêcher les contournements concurrents.
  PERFORM pg_advisory_xact_lock(hashtext('go-partage-quota:' || v_recipient::text), 0);
  PERFORM pg_advisory_xact_lock(hashtext(v_recipient::text), hashtext(v_card::text));

  SELECT
    count(*) FILTER (WHERE status = 'confirmed' AND donor_id = v_recipient),
    count(*) FILTER (WHERE status = 'confirmed' AND recipient_id = v_recipient)
  INTO v_donations, v_receptions
  FROM public.transfers
  WHERE donor_id = v_recipient OR recipient_id = v_recipient;

  v_required := public.required_donations(v_receptions);
  IF v_donations < v_required THEN
    RAISE EXCEPTION
      'Quota non atteint : il faut au moins % don(s) confirmé(s) pour % réception(s) confirmée(s).',
      v_required, v_receptions;
  END IF;

  -- Une seule réception non confirmée à la fois.
  IF EXISTS (
    SELECT 1
    FROM public.transfers
    WHERE recipient_id = v_recipient
      AND status IN ('awaiting_recipient', 'disputed')
  ) THEN
    RAISE EXCEPTION
      'Ce membre a déjà un don en attente de confirmation. Les autres envois sont bloqués jusqu’à la confirmation ou l’annulation de ce don.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_donor AND status = 'active')
     OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_recipient AND status = 'active') THEN
    RAISE EXCEPTION 'Un des comptes est inactif.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.member_cards
    WHERE member_id = v_recipient AND card_id = v_card AND quantity > 0
  ) THEN
    RAISE EXCEPTION 'Le bénéficiaire possède déjà cette carte.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.transfers
    WHERE recipient_id = v_recipient AND card_id = v_card
      AND status IN ('awaiting_recipient', 'disputed')
  ) THEN
    RAISE EXCEPTION 'Le bénéficiaire a déjà un don en cours pour cette carte.';
  END IF;

  SELECT c.is_tradable_now, c.is_approved
  INTO v_tradable, v_approved
  FROM public.cards c
  WHERE c.id = v_card;

  IF NOT FOUND OR v_tradable IS NOT TRUE OR v_approved IS NOT TRUE THEN
    RAISE EXCEPTION 'Cette carte n’est plus disponible au don.';
  END IF;

  SELECT quantity
  INTO v_owned
  FROM public.member_cards
  WHERE member_id = v_donor AND card_id = v_card
  FOR UPDATE;

  IF NOT FOUND OR v_owned < 1 THEN
    RAISE EXCEPTION 'Le donneur ne possède plus cette carte.';
  END IF;
  IF v_offer_quantity > v_owned THEN
    RAISE EXCEPTION 'Quantité proposée indisponible.';
  END IF;

  IF v_owned > 1 THEN
    UPDATE public.member_cards
    SET quantity = quantity - 1, updated_at = now()
    WHERE member_id = v_donor AND card_id = v_card;
  ELSE
    DELETE FROM public.member_cards
    WHERE member_id = v_donor AND card_id = v_card;
  END IF;

  IF v_offer_quantity > 1 THEN
    UPDATE public.card_offers
    SET quantity = quantity - 1
    WHERE id = p_offer_id;
  ELSE
    UPDATE public.card_offers
    SET status = 'matched'
    WHERE id = p_offer_id;
  END IF;

  UPDATE public.card_requests
  SET status = 'matched'
  WHERE id = p_request_id;

  INSERT INTO public.transfers(
    donor_id, recipient_id, card_id, status, offer_id, request_id, offer_quantity_decremented
  )
  VALUES (
    v_donor, v_recipient, v_card, 'awaiting_recipient',
    p_offer_id, p_request_id, (v_offer_quantity > 1)
  )
  RETURNING id INTO v_transfer_id;

  RETURN v_transfer_id;
END;
$function$;
